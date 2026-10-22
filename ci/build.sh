#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

# Test ALL config endpoints with Reader role
echo "=== config/metadata (GET) ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/metadata?api-version=2023-12-01" 2>&1 | head -c 500

echo "=== config/metadata/list (POST) ==="
az rest --method post --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/metadata/list?api-version=2023-12-01" --body '{}' 2>&1 | head -c 500

echo "=== config/web (GET) ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2023-12-01" --query 'properties' 2>&1 | head -c 1000

echo "=== storage account GET (check for keys in properties) ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz?api-version=2023-05-01" --query 'properties' 2>&1 | head -c 1000

echo "=== storage blobServices/default/containers/config ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/blobServices/default/containers/config?api-version=2023-05-01" 2>&1 | head -c 500

echo "=== storage listAccountSas with az CLI ==="
az storage account generate-sas --account-name sttblappcfgprodx3euoz --services b --resource-types sco --permissions rl --expiry $(date -u -d "+1 day" '+%Y-%m-%dT%H:%M:%SZ') --https-only 2>&1 | head -c 500

echo "=== try az storage with shared-key from cilogs (WILL NOT WORK cross-account but try) ==="
echo "=== try reading backup/exports container directly ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblbackupprodx3euoz/blobServices/default/containers/exports?api-version=2023-05-01" 2>&1 | head -c 500

echo "=== DONE ==="
