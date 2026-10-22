#!/usr/bin/env bash
# Confirm ACR push grant (decode token access claim) + find how the app re-pulls (webhook/CD) + restart test.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"; APP="app-tbl-storefront-prod"
ACR="crtblplatprodx3euoz"; AUD="api://AzureADTokenExchange"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
oidc(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
jwt(){ python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=0))" "$1" 2>/dev/null; }

AAD=$(oidc "https://management.azure.com/.default")
RT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/exchange" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=access_token&service=$ACR.azurecr.io&tenant=$TEN&access_token=$AAD" | jq -r .refresh_token)
echo "### refresh_token len=${#RT}"
for SCOPE in "repository:tebamoto-reporting-api:pull,push" "repository:ctfnew$RANDOM:pull,push" "registry:catalog:*"; do
  AT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/token" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=refresh_token&service=$ACR.azurecr.io&scope=$SCOPE&refresh_token=$RT" | jq -r '.access_token // empty')
  echo "### scope=[$SCOPE] granted access claim:"
  if [ -n "$AT" ]; then jwt "$AT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('   ', json.dumps(d.get('access', d.get('permissions',{})))); " 2>/dev/null; else echo "   (no token)"; fi
done

echo "### existing tags on tebamoto-reporting-api (anon pull):"
PT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/token" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=refresh_token&service=$ACR.azurecr.io&scope=repository:tebamoto-reporting-api:pull&refresh_token=$RT" | jq -r .access_token)
curl -s -H "Authorization: Bearer $PT" "https://$ACR.azurecr.io/v2/tebamoto-reporting-api/tags/list"; echo
echo "### _catalog with deployer token:"
CT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/token" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=refresh_token&service=$ACR.azurecr.io&scope=registry:catalog:*&refresh_token=$RT" | jq -r .access_token)
curl -s -H "Authorization: Bearer $CT" "https://$ACR.azurecr.io/v2/_catalog"; echo

echo "### ACR webhooks (auto-deploy to app?):"
curl -s -H "Authorization: Bearer $AAD" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/$ACR/webhooks?api-version=2023-07-01" | jq -r '.value[]? | "   "+.name+" status="+.properties.status+" scope="+(.properties.scope//"*")+" actions="+(.properties.actions|tostring)'
echo "### app restart test (OIDC):"
echo "   restart -> $(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $AAD" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/restart?api-version=2023-12-01")"
echo "   onedeploy GET -> $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AAD" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/extensions/onedeploy?api-version=2023-12-01")"
echo "   site write test (PATCH tags) -> $(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $AAD" -H 'Content-Type: application/json' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP?api-version=2023-12-01" -d '{"tags":{"x":"y"}}')"
echo "### scm/kudu publish test (OIDC AAD bearer to scm):"
echo "   scm /api/settings -> $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AAD" "https://$APP.scm.azurewebsites.net/api/settings")"
echo "=== DONE ==="
