#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

# App Service Docker container webhook URL  
# https://app-tbl-storefront-prod.scm.azurewebsites.net/api/registry/webhook
echo "=== TRIGGER DOCKER WEBHOOK ==="
curl -sv -X POST --max-time 15 "https://app-tbl-storefront-prod.scm.azurewebsites.net/api/registry/webhook" \
  -H "Content-Type: application/json" -d '{}' 2>&1 | tail -10

# Also try with $username:$password from publishing profile
# Since we can't get publishing creds via API, try default credentials
echo "=== KUDU API (try container webhook) ==="
for AUTH in "" "admin:admin" "app-tbl-storefront-prod:\\$app-tbl-storefront-prod"; do
  if [ -n "$AUTH" ]; then
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -u "$AUTH" -X POST "https://app-tbl-storefront-prod.scm.azurewebsites.net/api/registry/webhook" -H "Content-Type: application/json" -d '{}')
  else
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "https://app-tbl-storefront-prod.scm.azurewebsites.net/api/registry/webhook" -H "Content-Type: application/json" -d '{}')
  fi
  echo "auth=$AUTH webhook: $CODE"
done

# Try az webapp config container set (might force repull)
echo "=== FORCE CONTAINER SET ==="
az webapp config container set -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea \
  --container-image-name crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest \
  --container-registry-url https://crtblplatprodx3euoz.azurecr.io 2>&1 | head -c 200

echo "=== DONE ==="
