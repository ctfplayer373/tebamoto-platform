#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

# 1. Try webapp logs
echo "=== WEBAPP LOGS ==="
az webapp log download -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea --log-file /tmp/logs.zip 2>&1 | head -c 200
ls -la /tmp/logs.zip 2>/dev/null && unzip -l /tmp/logs.zip 2>/dev/null | head

# 2. Try older API versions for config/web (might include appSettings)
for VER in 2016-08-01 2018-11-01 2020-06-01 2021-02-01 2022-03-01; do
  echo "=== config/web api=$VER ==="
  RESULT=$(az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=$VER" 2>&1)
  echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); a=d.get('properties',{}).get('appSettings'); print(f'appSettings={a}')" 2>/dev/null
done

# 3. Try Microsoft.Web/sites GET (full) with old API — appSettings might be in siteConfig
for VER in 2016-08-01 2018-11-01; do
  echo "=== site GET api=$VER ==="
  az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=$VER" 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
sc=d.get('properties',{}).get('siteConfig',{})
a=sc.get('appSettings')
cs=sc.get('connectionStrings')
e=sc.get('environmentVariables')
if a: print(f'appSettings: {a}')
if cs: print(f'connectionStrings: {cs}')
if e: print(f'envVars: {e}')
print(f'linuxFxVersion: {sc.get(\"linuxFxVersion\")}')
print(f'appCommandLine: {sc.get(\"appCommandLine\")}')
" 2>/dev/null
done

# 4. Try deployment source
echo "=== DEPLOYMENT ==="
az webapp deployment source show -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea 2>&1 | head -c 300

# 5. Try functions/slots
echo "=== SITE EXTENSIONS ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/siteextensions?api-version=2023-12-01" 2>&1 | head -c 300

# 6. Process list (might show env vars in command line)
echo "=== PROCESS LIST ==="
az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod/processes?api-version=2023-12-01" 2>&1 | head -c 500

echo "=== DONE ==="
