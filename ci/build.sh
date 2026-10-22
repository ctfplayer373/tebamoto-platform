#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

# OIDC SP has Reader role. Reader can list containers.
# Let's try to list BLOBS in each container on each storage account
echo "=== LIST BLOBS (Reader might list even if can't read) ==="
for ACCT in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do
  for CONT in $(az storage container list --account-name $ACCT --auth-mode login --query '[].name' -o tsv 2>/dev/null); do
    echo "--- $ACCT/$CONT ---"
    az storage blob list --account-name $ACCT -c $CONT --auth-mode login --query '[].name' -o tsv 2>&1 | head -20
  done 2>&1
done

# Alternative: list blobs via ARM API (not data plane)
echo "=== LIST BLOBS VIA ARM ==="
for ACCT in sttblappcfgprodx3euoz sttblbackupprodx3euoz; do
  for CONT in config exports; do
    echo "--- $ACCT/$CONT via ARM ---"
    az rest --method get --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Storage/storageAccounts/$ACCT/blobServices/default/containers/$CONT/blobs?api-version=2023-05-01" 2>&1 | head -c 500
    echo
  done
done

# Try webapp config show (different from list)
echo "=== WEBAPP CONFIG SHOW ==="
az webapp config show -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea --query '{linuxFxVersion:linuxFxVersion, appCommandLine:appCommandLine, autoHealEnabled:autoHealEnabled}' 2>&1

# Check environment variables via deployment list
echo "=== DEPLOYMENT LIST ==="
az webapp deployment list-publishing-credentials -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea 2>&1 | head -c 300

echo "=== DONE ==="
