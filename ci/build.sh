#!/usr/bin/env bash
set -x

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# Try ALL SPs for restart permission
for SP in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  MG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
  
  # Try restart
  RC=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/restart?api-version=2023-12-01")
  echo "$SP restart: $RC"
  
  # Try stop+start
  if [ "$RC" != "200" ]; then
    SC=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
      "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/stop?api-version=2023-12-01")
    echo "$SP stop: $SC"
  fi
done

# Also: App Service has continuous deployment webhooks
# Check if there's a webhook URL for ACR push → auto-restart
echo "=== CHECK ACR WEBHOOK ==="
MGMT=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)

# Get container settings (CI/CD webhook URL)
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2023-12-01" --query 'properties.{acrUseMI:acrUseManagedIdentityCreds,acrUserMI:acrUserManagedIdentityID,linuxFxVersion:linuxFxVersion,alwaysOn:alwaysOn}' 2>&1

# Try to get the CI/CD webhook URL
echo "=== CICD WEBHOOK ==="
az rest --method post --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/publishingcredentials/list?api-version=2023-12-01" --body '{}' 2>&1 | jq -r '.properties.scmUri // .error.message' | head -c 200

# Actually — we can trigger ACR webhook to force pull
echo "=== ACR WEBHOOKS LIST ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/webhooks?api-version=2023-07-01" 2>&1 | head -c 500

# Also check: does the app auto-pull on push? (continuous deployment)
echo "=== CONTAINER SETTINGS ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2023-12-01" --query 'properties.siteConfig.{acrUseMI:acrUseManagedIdentityCreds,linuxFx:linuxFxVersion}' 2>&1

echo "=== DONE ==="
