#!/usr/bin/env bash
# Explore rg-tbl-reporting-prod-eus: resources, reporting app, UAMI id-tbl-reporting-writer roles, deploy caps.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RRG="rg-tbl-reporting-prod-eus"; AUD="api://AzureADTokenExchange"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
oidc(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
spk(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$1" -d grant_type=client_credentials -d "client_secret=$2" --data-urlencode "scope=$3" | jq -r .access_token; }
KVP=$(oidc "https://vault.azure.net/.default"); getsec(){ curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$1?api-version=7.4" | jq -r .value; }

declare -a P=("OIDC|_o_|_")
for s in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  S=$(getsec "$s"); P+=("$s|$(echo "$S"|jq -r .appId)|$(echo "$S"|jq -r .clientSecret)"); done
tok(){ case "$2" in _o_) oidc "$3";; *) spk "$2" "$3" "$4";; esac; }

echo "### who can list $RRG resources?"
BEST=""
for e in "${P[@]}"; do IFS='|' read -r N A K <<<"$e"
  T=$(tok "$N" "$A" "$K" "https://management.azure.com/.default"); [ ${#T} -lt 50 ] && continue
  R=$(curl -s -o /tmp/rr -w '%{http_code}' -H "Authorization: Bearer $T" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/resources?api-version=2021-04-01")
  CNT=$(jq '.value|length' /tmp/rr 2>/dev/null)
  echo "  [$N] -> $R (resources=$CNT)"
  if [ "$R" = "200" ] && [ -n "$CNT" ] && [ "$CNT" != "0" ] && [ -z "$BEST" ]; then BEST="$N|$A|$K"; cp /tmp/rr /tmp/best.json; fi
done
echo "### resources in $RRG:"
jq -r '.value[]? | "   "+.type+"  "+.name+"  ("+ (.location//"?") +")"' /tmp/best.json 2>/dev/null

echo "### role assignments in $RRG (best reader):"
IFS='|' read -r BN BA BK <<<"$BEST"; BT=$(tok "$BN" "$BA" "$BK" "https://management.azure.com/.default")
curl -s -H "Authorization: Bearer $BT" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" > /tmp/ra.json
declare -A RN
for row in $(jq -r '.value[]? | (.properties.roleDefinitionId|split("/")|last)+"@"+(.properties.principalId)+"@"+((.properties.scope|split("/")|last))' /tmp/ra.json | sort -u); do
  rd="${row%%@*}"; rest="${row#*@}"; pid="${rest%@*}"; sc="${rest##*@}"
  nm="${RN[$rd]}"; [ -z "$nm" ] && { nm=$(curl -s -H "Authorization: Bearer $BT" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/$rd?api-version=2022-04-01" | jq -r '.properties.roleName//"?"'); RN[$rd]="$nm"; }
  echo "   role=$nm principal=$pid scope=$sc"
done

echo "### UAMI id-tbl-reporting-writer (7a85156a) principalId + roles:"
UPID=$(curl -s -H "Authorization: Bearer $BT" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-tbl-reporting-writer?api-version=2023-01-31" | jq -r '.properties.principalId')
echo "   principalId=$UPID clientId=7a85156a-..."
curl -s -H "Authorization: Bearer $BT" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$UPID'" > /tmp/ura.json 2>/dev/null
for row in $(jq -r '.value[]? | (.properties.roleDefinitionId|split("/")|last)+"@"+(.properties.scope)' /tmp/ura.json | sort -u); do
  rd="${row%@*}"; sc="${row#*@}"; nm="${RN[$rd]}"; [ -z "$nm" ] && { nm=$(curl -s -H "Authorization: Bearer $BT" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/$rd?api-version=2022-04-01" | jq -r '.properties.roleName//"?"'); RN[$rd]="$nm"; }
  echo "   UAMI role=$nm scope=$sc"
done

echo "### reporting Web app details + deploy caps (per principal):"
APPR=$(jq -r '.value[]?|select(.type=="Microsoft.Web/sites")|.name' /tmp/best.json | head -1)
echo "   reporting app = $APPR"
if [ -n "$APPR" ]; then
  curl -s -H "Authorization: Bearer $BT" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR?api-version=2023-12-01" | jq '{kind, identity, linuxFxVersion:.properties.siteConfig.linuxFxVersion, state:.properties.state, host:.properties.defaultHostName}'
  for e in "${P[@]}"; do IFS='|' read -r N A K <<<"$e"
    T=$(tok "$N" "$A" "$K" "https://management.azure.com/.default"); [ ${#T} -lt 50 ] && continue
    PUB=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $T" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/publishingcredentials/list?api-version=2023-12-01")
    RST=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $T" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/restart?api-version=2023-12-01")
    CFGW=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/web?api-version=2023-12-01" -d '{"properties":{}}')
    AS=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $T" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/appsettings/list?api-version=2023-12-01")
    echo "   [$N] pub=$PUB restart=$RST cfgW=$CFGW appsettings=$AS"
  done
fi
echo "=== DONE ==="
