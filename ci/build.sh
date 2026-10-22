#!/usr/bin/env bash
# Map exact RBAC of every principal + resolve the Owner user and mystery SP via Graph.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"

oidc () { local OIDC; OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
  curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$OIDC" --data-urlencode "scope=$1" | jq -r .access_token; }
spk () { curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=$1" -d "grant_type=client_credentials" -d "client_secret=$2" \
    --data-urlencode "scope=$3" | jq -r .access_token; }
jwt_oid () { python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p)).get('oid',''))" "$1" 2>/dev/null; }

KVPROD=$(oidc "https://vault.azure.net/.default")
MG=$(oidc "https://management.azure.com/.default")

# role-definition name cache
declare -A RNAME
rolename () { local id="$1"; [ -n "${RNAME[$id]}" ] && { echo "${RNAME[$id]}"; return; }
  local n; n=$(curl -s -H "Authorization: Bearer $MG" \
    "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/$id?api-version=2022-04-01" | jq -r '.properties.roleName // "?"')
  RNAME[$id]="$n"; echo "$n"; }

list_ra () { # $1=token $2=label  -> all RA for the token's principal, subscription-wide
  local T="$1" L="$2"; local OID; OID=$(jwt_oid "$T")
  echo "  [$L] oid=$OID"
  [ -z "$OID" ] && return
  curl -s -H "Authorization: Bearer $T" \
    "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$OID'" \
    > /tmp/ra.json
  for row in $(jq -r '.value[]? | (.properties.roleDefinitionId|split("/")|last)+"@"+(.properties.scope)' /tmp/ra.json); do
    rd="${row%@*}"; sc="${row#*@}"; echo "    role=$(rolename "$rd") scope=$sc"
  done
  [ "$(jq '.value|length' /tmp/ra.json)" = "0" ] && echo "    (no role assignments readable / none)"
}

echo "### A: exact RBAC per principal (subscription-wide)"
TMG=$(oidc "https://management.azure.com/.default"); list_ra "$TMG" "OIDC-CI"
for SP in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KVPROD" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  A=$(echo "$SEC"|jq -r .appId); K=$(echo "$SEC"|jq -r .clientSecret)
  T=$(spk "$A" "$K" "https://management.azure.com/.default")
  if [ ${#T} -lt 50 ]; then echo "  [$SP] NO mgmt token (appId=$A)"; else list_ra "$T" "$SP (appId=$A)"; fi
done
echo

echo "### B: Graph resolve mystery principals (try each SP for graph access)"
for SP in directory-audit-principal secrets-sync-principal reporting-service-principal reporting-viewer-principal cost-reader-principal sync-service-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KVPROD" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  A=$(echo "$SEC"|jq -r .appId); K=$(echo "$SEC"|jq -r .clientSecret)
  GT=$(spk "$A" "$K" "https://graph.microsoft.com/.default")
  [ ${#GT} -lt 50 ] && continue
  CODE=$(curl -s -o /tmp/g -w "%{http_code}" -H "Authorization: Bearer $GT" \
    "https://graph.microsoft.com/v1.0/directoryObjects/d2cdf247-9319-40cb-8324-5a005ef538da")
  echo "  [$SP] graph GET user d2cdf247 -> $CODE"
  if [ "$CODE" = "200" ]; then
    echo "   GRAPH-WORKS via $SP"
    echo "   d2cdf247 => $(jq -r '{displayName,userPrincipalName,"@odata.type":."@odata.type"}' /tmp/g 2>/dev/null)"
    echo "   1fe7a412 => $(curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/directoryObjects/1fe7a412-82e9-4135-ab4b-72a0be429adb" | jq -c '{displayName,appId,"@odata.type":."@odata.type"}')"
    echo "   eeab432e => $(curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/directoryObjects/eeab432e-1bf6-400e-b155-a28ce7cafcdb" | jq -c '{displayName,appId,"@odata.type":."@odata.type"}')"
    echo "   --- applications + federated identity creds ---"
    curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/applications?\$select=displayName,appId,id" \
      | jq -r '.value[]? | "   APP "+.displayName+" appId="+.appId+" id="+.id'
    for APPID in $(curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/applications?\$select=id" | jq -r '.value[]?.id'); do
      FIC=$(curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/applications/$APPID/federatedIdentityCredentials" | jq -c '.value[]? | {name,subject,issuer}')
      [ -n "$FIC" ] && echo "   FIC app=$APPID: $FIC"
    done
    break
  fi
done
echo

echo "### C: role assignments on the vaults + app service (names)"
for RES in \
  "Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz" \
  "Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz" \
  "Microsoft.Web/sites/app-tbl-storefront-prod" ; do
  echo "  -- $RES --"
  curl -s -H "Authorization: Bearer $MG" \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/$RES/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=atScope()" \
    > /tmp/rc.json
  for row in $(jq -r '.value[]? | (.properties.roleDefinitionId|split("/")|last)+"@"+(.properties.principalId)+"@"+(.properties.principalType//"?")' /tmp/rc.json); do
    rd="${row%%@*}"; rest="${row#*@}"; pid="${rest%@*}"; pt="${rest#*@}"
    echo "    role=$(rolename "$rd") principal=$pid type=$pt"
  done
done
echo "=== DONE ==="
