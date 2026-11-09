#!/usr/bin/env bash
# Deploy identity for BiblioStatus (Workload Identity Federation): replaces the shared,
# broad `github-deploy` account for this repo. GitHub Actions on AnttiRask/BiblioStatus, branch main
# only, impersonates a narrow service account. No key is ever created.
#
# Why: BiblioStatus and FillariStatus used to share `github-deploy` (Cloud Run admin,
# storage admin and service-account user on the whole project, plus the secrets), and
# the login provider checked the repository but not the branch. Each repo now gets its
# own account with resource-level permissions, as TrackTeller, TuneTeller and Gallery
# of the Day have. The sibling script (FillariStatus) does the same for the other repo.
#
# Run it by hand, as the project owner, in this order:
#   1. DRY_RUN=1 infra/setup_keyless_deploy.sh     (prints what it would change)
#   2. infra/setup_keyless_deploy.sh               (does it)
#   3. change `service_account:` in .github/workflows/deploy_shiny_app.yml to the
#      value printed at the end, merge, run the workflow by hand, check the result
# `github-deploy` was NOT touched by this script: until both repos had deployed with their
# new account, putting `github-deploy` back in the workflow was the way back. Both did, and
# it was stripped of its roles and deleted by hand on 2026-11-09.
#
# Every step prints what it does and stops on the first error. Re-running skips what
# already exists. Step 1 (the provider's condition) is the same in both scripts.
set -euo pipefail

PROJECT=bibliostatus-app
REGION=europe-north1
NUMBER=884476669514
SERVICE=bibliostatus-app
REPO=AnttiRask/BiblioStatus
OTHER_REPO=AnttiRask/FillariStatus

DEPLOY_ID=bibliostatus-deploy
DEPLOY_SA=${DEPLOY_ID}@${PROJECT}.iam.gserviceaccount.com
RUNTIME_SA=bibliostatus-runtime@${PROJECT}.iam.gserviceaccount.com
COMPUTE_SA=${NUMBER}-compute@developer.gserviceaccount.com   # the account Cloud Build runs as
POOL=github
PROVIDER=github-oidc
SOURCE_BUCKET=${PROJECT}_cloudbuild                          # `gcloud builds submit` uploads here
ROLE_ID=deployBucketLister
BACKUP_DIR=${HOME}/iam-backups-$(date +%F)

DRY_RUN=${DRY_RUN:-}

step() { echo; echo "== $*"; }
# Anything that changes the cloud goes through run(); with DRY_RUN=1 it is only printed.
run() {
  if [ -n "$DRY_RUN" ]; then echo "[dry run] $*"; else "$@" </dev/null; fi
}
g() { run gcloud "$@" --project "$PROJECT"; }
quiet_ok() { "$@" >/dev/null 2>&1 </dev/null; }

# A service account that was created seconds ago is not always visible to other
# Google APIs yet. Retry a few times, showing every error; give up loudly.
retry() {
  local n
  for n in 1 2 3 4 5 6 7 8; do
    if "$@"; then return 0; fi
    echo "attempt $n failed; waiting 15 s for the new account to propagate..." >&2
    sleep 15
  done
  echo "giving up after 8 attempts" >&2
  return 1
}

[ -n "$DRY_RUN" ] && echo "DRY RUN: nothing is changed"

step "0. Save the current policies (to $BACKUP_DIR)"
if [ -n "$DRY_RUN" ]; then
  echo "[dry run] would save the project's IAM policy and github-deploy's policy"
else
  mkdir -p "$BACKUP_DIR"
  gcloud projects get-iam-policy "$PROJECT" --format=json </dev/null > "$BACKUP_DIR/${PROJECT}.project-policy.$(date +%H%M%S).json"
  if gcloud iam service-accounts describe "github-deploy@${PROJECT}.iam.gserviceaccount.com" --project "$PROJECT" >/dev/null 2>&1 </dev/null; then
    gcloud iam service-accounts get-iam-policy "github-deploy@${PROJECT}.iam.gserviceaccount.com" --project "$PROJECT" --format=json </dev/null > "$BACKUP_DIR/${PROJECT}.github-deploy-policy.$(date +%H%M%S).json"
  else
    echo "github-deploy no longer exists (deleted 2026-11-09): nothing to save for it"
  fi
  ls -l "$BACKUP_DIR" | tail -3
fi

step "1. Provider '$PROVIDER': both repos, refs/heads/main only"
WANT="assertion.repository in ['${REPO}','${OTHER_REPO}'] && assertion.ref=='refs/heads/main'"
HAVE=$(gcloud iam workload-identity-pools providers describe "$PROVIDER" --location global --workload-identity-pool "$POOL" --project "$PROJECT" --format='value(attributeCondition)' </dev/null)
if [ "$HAVE" = "$WANT" ] || [ "$HAVE" = "assertion.repository in ['${OTHER_REPO}','${REPO}'] && assertion.ref=='refs/heads/main'" ]; then
  echo "already limited to main"
else
  echo "was: $HAVE"
  g iam workload-identity-pools providers update-oidc "$PROVIDER" \
    --location global --workload-identity-pool "$POOL" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition "$WANT"
fi

step "2. Deploy service account"
if quiet_ok gcloud iam service-accounts describe "$DEPLOY_SA" --project "$PROJECT"; then
  echo "exists"
else
  g iam service-accounts create "$DEPLOY_ID" --display-name "BiblioStatus deploy (GitHub Actions)"
fi

step "3. Only this repo (via the pool) may impersonate it"
g iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

step "4. Narrow permissions, resource-level where possible"
echo "- deploy to the one service"
retry g run services add-iam-policy-binding "$SERVICE" --region "$REGION" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/run.developer
echo "- act as the runtime account and as the build account (the default compute account)"
retry g iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/iam.serviceAccountUser
retry g iam service-accounts add-iam-policy-binding "$COMPUTE_SA" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/iam.serviceAccountUser
echo "- read the image from the source-deploy repository"
g artifacts repositories add-iam-policy-binding cloud-run-source-deploy --location "$REGION" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/artifactregistry.reader
echo "- upload the build source to its bucket (that bucket only; shared with the other app)"
run gcloud storage buckets add-iam-policy-binding "gs://${SOURCE_BUCKET}" --project "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/storage.objectAdmin
run gcloud storage buckets add-iam-policy-binding "gs://${SOURCE_BUCKET}" --project "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/storage.legacyBucketReader
echo "- start and follow builds, and list buckets (gcloud needs it to find the staging bucket)"
g projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/cloudbuild.builds.editor --condition=None
if quiet_ok gcloud iam roles describe "$ROLE_ID" --project "$PROJECT"; then
  echo "custom role exists"
else
  g iam roles create "$ROLE_ID" --title "Deploy bucket lister" --permissions storage.buckets.list
fi
g projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role "projects/${PROJECT}/roles/${ROLE_ID}" --condition=None

step "5. What the new account can do now"
if [ -z "$DRY_RUN" ]; then
  gcloud projects get-iam-policy "$PROJECT" --format=json </dev/null | python3 -c "
import json,sys
me='serviceAccount:${DEPLOY_SA}'
for b in json.load(sys.stdin)['bindings']:
    if me in b['members']: print('  project-level:', b['role'])
"
fi

step "Done. Values for the workflow:"
echo "workload_identity_provider: projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}   (unchanged)"
echo "service_account:            ${DEPLOY_SA}"
echo
echo "Note: the older, shared github-deploy account was deleted on 2026-11-09, after both repos had deployed with their own account."
