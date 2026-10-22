#!/usr/bin/env bash
# Determine deploy model (container vs code), the UAMI's identity+access, KV keys/certs/policies.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"; APP="app-tbl-storefront-prod"
AUD="api://AzureADTokenExchange"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
OMG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
OKV=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
ARM(){ curl -s -H "Authorization: Bearer $OMG" "https://management.azure.com$1"; }

echo "### D: ALL resources in RG (find reporting app / archive storage)"
ARM "/subscriptions/$SUB/resourceGroups/$RG/resources?api-version=2021-04-01" | jq -r '.value[]? | "   "+.type+"  "+.name'
echo "### ALL Microsoft.Web/sites:"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites?api-version=2023-12-01" | jq -r '.value[]? | "   site="+.name+" identity="+(.identity.type//"none")+" uami="+((.identity.userAssignedIdentities//{})|keys|join(","))'

echo "### A: App Service site (deploy model + identity)"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP?api-version=2023-12-01" > /tmp/site.json
jq '{kind, identity, linuxFxVersion:.properties.siteConfig.linuxFxVersion, appCommandLine:.properties.siteConfig.appCommandLine, state:.properties.state, hostNames:.properties.hostNames, serverFarmId:.properties.serverFarmId}' /tmp/site.json
echo "### siteConfig/web:"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/web?api-version=2023-12-01" | jq '{linuxFxVersion:.properties.linuxFxVersion, appCommandLine:.properties.appCommandLine, alwaysOn:.properties.alwaysOn, acrUseManagedIdentityCreds:.properties.acrUseManagedIdentityCreds, scmType:.properties.scmType}'
echo "### metadata (deployment source):"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/metadata/list?api-version=2023-12-01" 2>/dev/null | jq -c '.properties // {err:.error.code}' 2>/dev/null
echo "### sourcecontrols / deployment:"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/deployments?api-version=2023-12-01" | jq -c '[.value[]?|{id,status,message,author,end_time}]|.[0:3]'

echo
echo "### B: user-assigned identities on the app + in RG"
jq -r '.identity.userAssignedIdentities // {} | keys[]' /tmp/site.json
echo "### all UAMIs in RG:"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31" | jq -r '.value[]? | "   "+.name+" clientId="+.properties.clientId+" principalId="+.properties.principalId'
# resolve UAMI 7a85156a principalId and its roles
UPID=$(ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31" | jq -r '.value[]?|select(.properties.clientId=="7a85156a-01c4-4e61-8472-40a92107159b")|.properties.principalId')
echo "### UAMI 7a85156a principalId=$UPID"
echo "### its role assignments (RG query, incl inherited):"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$UPID'" | jq -r '.value[]? | "   role="+(.properties.roleDefinitionId|split("/")|last)+" scope="+.properties.scope'
echo "### system MSI eeab432e role assignments:"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'eeab432e-1bf6-400e-b155-a28ce7cafcdb'" | jq -r '.value[]? | "   role="+(.properties.roleDefinitionId|split("/")|last)+" scope="+.properties.scope'

echo
echo "### C: KV deep — kv-tbl-prod access policies / keys / certs / deleted"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz?api-version=2023-07-01" | jq '{rbac:.properties.enableRbacAuthorization, policies:[.properties.accessPolicies[]?|{objectId,secrets:.permissions.secrets,keys:.permissions.keys,certs:.permissions.certificates}]}'
echo "### kv-tbl-prod KEYS:";   curl -s -H "Authorization: Bearer $OKV" "https://kv-tbl-prod-x3euoz.vault.azure.net/keys?api-version=7.4" | jq -r '.value[]?.kid, (.error.message//empty)'
echo "### kv-tbl-prod CERTS:";  curl -s -H "Authorization: Bearer $OKV" "https://kv-tbl-prod-x3euoz.vault.azure.net/certificates?api-version=7.4" | jq -r '.value[]?.id, (.error.message//empty)'
echo "### kv-tbl-prod DELETED secrets:"; curl -s -H "Authorization: Bearer $OKV" "https://kv-tbl-prod-x3euoz.vault.azure.net/deletedsecrets?api-version=7.4" | jq -r '.value[]?.id, (.error.message//empty)'
echo "### kv-tbl-sec vault props:"
ARM "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01" | jq '{rbac:.properties.enableRbacAuthorization, policies:[.properties.accessPolicies[]?|{objectId,secrets:.permissions.secrets}]}'
echo "=== DONE ==="
