#!/bin/bash
# Deploy BiblioStatus to Google Cloud Run (self-contained)

set -euo pipefail

# ---- Configuration (override via env vars) ----------------------------------
PROJECT_ID="${GCP_PROJECT:-bibliostatus-app}"
REGION="${GCP_REGION:-europe-north1}"
SERVICE_NAME="${GCP_SERVICE_NAME:-bibliostatus-app}"

# Artifact Registry repo name Cloud Build uses for "gcloud builds submit --tag"
# (You can change this, but then you must ensure the repo exists)
AR_REPO="${GCP_AR_REPO:-cloud-run-source-deploy}"
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/$SERVICE_NAME"

# ---- Colors ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== BiblioStatus Deployment ===${NC}"
echo -e "${YELLOW}Target project:${NC} ${PROJECT_ID}"
echo -e "${YELLOW}Region:${NC} ${REGION}"
echo -e "${YELLOW}Service:${NC} ${SERVICE_NAME}"
echo -e "${YELLOW}Image:${NC} ${IMAGE}"
echo ""

# ---- Preconditions ----------------------------------------------------------
if ! command -v gcloud &>/dev/null; then
  echo -e "${RED}Error: gcloud CLI is not installed${NC}"
  exit 1
fi

ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' || true)"
if [[ -z "${ACTIVE_ACCT}" ]]; then
  echo -e "${YELLOW}No active gcloud login found. Running: gcloud auth login${NC}"
  gcloud auth login
  ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' || true)"
fi
echo -e "${YELLOW}Using account:${NC} ${ACTIVE_ACCT}"
echo ""

# Ensure project exists (note: creation may fail if billing/org policies block it)
if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
  echo -e "${YELLOW}Project ${PROJECT_ID} not found. Attempting to create...${NC}"
  gcloud projects create "$PROJECT_ID" --name="BiblioStatus"
  echo -e "${YELLOW}NOTE:${NC} You may still need to link a billing account for builds/deploys."
fi

# Enable required APIs (idempotent)
echo -e "${YELLOW}Enabling required APIs...${NC}"
gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  --project "$PROJECT_ID"

# ---- Build -----------------------------------------------------------------
echo -e "${GREEN}Building container image...${NC}"
gcloud builds submit \
  --tag "$IMAGE" \
  --region "$REGION" \
  --timeout 3600 \
  --project "$PROJECT_ID"

# Optional guardrail: confirm the image manifest is reachable in THIS project
echo -e "${YELLOW}Verifying image exists in Artifact Registry...${NC}"
gcloud artifacts docker images describe "$IMAGE" \
  --project "$PROJECT_ID" \
  --location "$REGION" \
  >/dev/null

# ---- Deploy ----------------------------------------------------------------
echo -e "${GREEN}Deploying to Cloud Run...${NC}"
gcloud run deploy "$SERVICE_NAME" \
  --image "$IMAGE" \
  --platform managed \
  --region "$REGION" \
  --allow-unauthenticated \
  --memory 1Gi \
  --timeout 300 \
  --project "$PROJECT_ID"

SERVICE_URL="$(gcloud run services describe "$SERVICE_NAME" \
  --region "$REGION" \
  --format="value(status.url)" \
  --project "$PROJECT_ID")"

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "Your app is live at: ${GREEN}${SERVICE_URL}${NC}"
echo ""
