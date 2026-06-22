#!/usr/bin/env bash
# ============================================================
# deploy-webapp.sh — Deploy the Agreement Content Viewer web app
# to Azure App Service (Linux, Node.js)
#
# Usage:
#   ./deploy-webapp.sh
#
# Prerequisites:
#   - Azure CLI installed and logged in (with MFA satisfied)
#   - Zip utility available
# ============================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-Agentic-workflow}"
LOCATION="${LOCATION:-centralus}"
APP_NAME="${APP_NAME:-AgreementsApp-fwc4}"
PLAN_NAME="${PLAN_NAME:-${APP_NAME}-plan}"
SKU="${SKU:-B3}"
RUNTIME="${RUNTIME:-NODE:22-lts}"
WEBAPP_DIR="${WEBAPP_DIR:-webapp}"
ENV_FILE="${ENV_FILE:-${WEBAPP_DIR}/.env}"

# Load deployment env vars if present. This supports centralizing Cosmos
# settings in one place for local and deployed environments.
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# ── 1. Verify Azure CLI login ─────────────────────────────────
echo "[1/6] Verifying Azure CLI session..."
if ! az account show --output none 2>/dev/null; then
  echo "Not logged in. Starting login..."
  az login
fi
echo "  Subscription: $(az account show --query name -o tsv)"

# ── 2. Ensure resource group ──────────────────────────────────
echo "[2/6] Ensuring resource group '${RESOURCE_GROUP}'..."
if az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null; then
  echo "  Resource group already exists."
else
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
fi

# ── 3. Create App Service Plan ────────────────────────────────
echo "[3/6] Creating App Service Plan '${PLAN_NAME}' (SKU: ${SKU}, Linux)..."
az appservice plan create \
  --name "$PLAN_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --sku "$SKU" \
  --is-linux \
  --location "$LOCATION" \
  --output none

# ── 4. Create Web App ─────────────────────────────────────────
echo "[4/6] Creating Web App '${APP_NAME}'..."
az webapp create \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" \
  --runtime "$RUNTIME" \
  --output none

# ── 5. Configure app settings ─────────────────────────────────
echo "[5/6] Configuring app settings..."
COSMOS_ENDPOINT="${COSMOS_ENDPOINT:-https://agreementscosmosdb2.documents.azure.com:443/}"
COSMOS_DATABASE="${COSMOS_DATABASE:-contracts}"
COSMOS_CONTAINER="${COSMOS_CONTAINER:-agreementMetadata}"
COSMOS_RESOURCE_GROUP="${COSMOS_RESOURCE_GROUP:-$RESOURCE_GROUP}"

COSMOS_USE_AAD="${COSMOS_USE_AAD:-false}"
COSMOS_CONNECTION_STRING="${COSMOS_CONNECTION_STRING:-}"
COSMOS_KEY="${COSMOS_KEY:-}"

if [[ -z "$COSMOS_CONNECTION_STRING" && -z "$COSMOS_KEY" && ! "$COSMOS_USE_AAD" =~ ^([Tt][Rr][Uu][Ee]|1)$ ]]; then
  echo "ERROR: Missing Cosmos credentials. Set COSMOS_CONNECTION_STRING, COSMOS_KEY, or COSMOS_USE_AAD=true."
  exit 1
fi

COSMOS_ACCOUNT_NAME="$(echo "$COSMOS_ENDPOINT" | sed -E 's#^https?://([^./]+)\..*$#\1#')"
if [[ -z "$COSMOS_ACCOUNT_NAME" || "$COSMOS_ACCOUNT_NAME" == "$COSMOS_ENDPOINT" ]]; then
  echo "ERROR: Could not parse Cosmos account name from COSMOS_ENDPOINT='$COSMOS_ENDPOINT'."
  exit 1
fi

echo "  Cosmos account   : ${COSMOS_ACCOUNT_NAME}"
echo "  Cosmos database  : ${COSMOS_DATABASE}"
echo "  Cosmos container : ${COSMOS_CONTAINER}"
echo "  Cosmos auth mode : $( [[ -n "$COSMOS_CONNECTION_STRING" ]] && echo "connection-string" || ([[ -n "$COSMOS_KEY" ]] && echo "key" || echo "aad") )"

# Validate target Cosmos resources up front to avoid runtime 500 errors.
if ! az cosmosdb sql database show \
  --account-name "$COSMOS_ACCOUNT_NAME" \
  --resource-group "$COSMOS_RESOURCE_GROUP" \
  --name "$COSMOS_DATABASE" \
  --output none 2>/dev/null; then
  echo "ERROR: Cosmos database '${COSMOS_DATABASE}' not found in account '${COSMOS_ACCOUNT_NAME}' (resource group '${COSMOS_RESOURCE_GROUP}')."
  exit 1
fi

if ! az cosmosdb sql container show \
  --account-name "$COSMOS_ACCOUNT_NAME" \
  --resource-group "$COSMOS_RESOURCE_GROUP" \
  --database-name "$COSMOS_DATABASE" \
  --name "$COSMOS_CONTAINER" \
  --output none 2>/dev/null; then
  echo "ERROR: Cosmos container '${COSMOS_CONTAINER}' not found in database '${COSMOS_DATABASE}' on account '${COSMOS_ACCOUNT_NAME}'."
  exit 1
fi

SETTINGS_ARGS=(
  "COSMOS_ENDPOINT=$COSMOS_ENDPOINT"
  "COSMOS_DATABASE=$COSMOS_DATABASE"
  "COSMOS_CONTAINER=$COSMOS_CONTAINER"
  "COSMOS_USE_AAD=$COSMOS_USE_AAD"
  "WEBSITE_NODE_DEFAULT_VERSION=~22"
  # Run Oryx build (npm install) on the server so dependencies in
  # package.json (dotenv, express, @azure/*) are installed at deploy time.
  "SCM_DO_BUILD_DURING_DEPLOYMENT=true"
  "ENABLE_ORYX_BUILD=true"
)

if [[ -n "$COSMOS_CONNECTION_STRING" ]]; then
  SETTINGS_ARGS+=("COSMOS_CONNECTION_STRING=$COSMOS_CONNECTION_STRING")
fi

if [[ -n "$COSMOS_KEY" ]]; then
  SETTINGS_ARGS+=("COSMOS_KEY=$COSMOS_KEY")
fi

az webapp config appsettings set \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings "${SETTINGS_ARGS[@]}" \
  --output none

# ── 6. Deploy code via zip ────────────────────────────────────
echo "[6/6] Deploying webapp code..."
DEPLOY_DIR=$(mktemp -d)
ZIP_PATH="${DEPLOY_DIR}/webapp.zip"

# Package the webapp directory (exclude .env and node_modules)
cd "$WEBAPP_DIR"
zip -r "$ZIP_PATH" . -x ".env" "node_modules/*" > /dev/null
cd ..

az webapp deploy \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src-path "$ZIP_PATH" \
  --type zip \
  --output none

# Cleanup
rm -rf "$DEPLOY_DIR"

# ── Summary ───────────────────────────────────────────────────
APP_URL="https://${APP_NAME}.azurewebsites.net"
echo ""
echo "✅ Deployment complete!"
echo ""
echo "  App Name : ${APP_NAME}"
echo "  URL      : ${APP_URL}"
echo "  Health   : ${APP_URL}/healthz"
echo "  Portal   : https://portal.azure.com/#resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${APP_NAME}"
echo ""
echo "Next steps:"
echo "  1. Confirm app settings in Azure Portal (Configuration)"
echo "  2. Verify the app at ${APP_URL}/healthz"


