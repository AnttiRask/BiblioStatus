# Deploying BiblioStatus to Google Cloud Run

The app runs as a Docker container on Cloud Run (project `bibliostatus-app`, region `europe-north1`, service `bibliostatus-app`) at <https://bibliostatus.youcanbeapirate.com>. **You normally don't deploy by hand**: merging a pull request does it.

## How a deploy happens

1. **A pull request** runs the test suite (`.github/workflows/tests.yml`). Work on a branch; don't push to `main` directly.
2. **Merging to `main`** starts `.github/workflows/deploy_shiny_app.yml` when the change touches the app or the build: `app/**` (except the nightly `app/libraries.sqlite` commit), `R/**`, `Dockerfile`, `.dockerignore`, `renv.lock`, `.Rprofile`, `renv/activate.R`, `renv/settings.json`. Documentation-only changes don't deploy.
3. The workflow also runs **every Monday at 04:00 UTC** (so the SQLite backup baked into the image is at most a week old, after Sunday's full data refresh) and **on demand**:

   ```bash
   gh workflow run deploy_shiny_app.yml --ref main
   ```

4. What the workflow does, in order:
   - runs the tests again; a failing test stops the deploy
   - logs in to Google Cloud **without a key file** (Workload Identity Federation, service account `github-deploy`)
   - builds the image with Cloud Build into Artifact Registry (`europe-north1-docker.pkg.dev/bibliostatus-app/cloud-run-source-deploy/bibliostatus-app`)
   - deploys it with `gcloud run deploy`: 1 GiB memory, 3600-second request timeout (the websocket limit; the app reconnects quietly when it is reached), concurrency 80, at most 3 instances, session affinity, running as the service account `bibliostatus-runtime`
   - labels the revision with the commit (`git-sha`)
   - **smoke test**: the service must carry this commit's label and answer HTTP 200 on `/`. It deliberately does not check `/health`: a data problem shouldn't turn a code deploy red.
5. The whole thing takes about 8 minutes. Deploys don't overlap: a newer one waits for the one that is running (and if several queue up, only the newest queued one runs).

The nightly data update (`.github/workflows/fetch_data.yml`) does **not** redeploy: the app reads the data from Turso. Only the SQLite backup in the image waits for the next deploy.

## Configuration and secrets

- **Runtime secrets** (`TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN`) come from Google Secret Manager (`turso-database-url`, `turso-auth-token`) and are set by the deploy workflow with `--set-secrets`. They are not in the image or in the repository.
- **GitHub secrets**: `GCP_PROJECT_ID`, `TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN` (for the data workflow) and `EMAIL_USERNAME`, `EMAIL_PASSWORD` (for the broken-URL alert).
- **Map tiles need no key** (Esri's keyless canvas).
- **Locally**, the credentials live in a git-ignored `.Renviron` (see `CLAUDE.md`).

## Checking a deploy

```bash
# The revision's commit label and the URL
gcloud run services describe bibliostatus-app --project bibliostatus-app --region europe-north1 \
    --format='value(status.url,metadata.labels.git-sha)'

# The app and its data
curl -s https://bibliostatus.youcanbeapirate.com/health     # "ok", or 503 and a reason
gcloud run services logs read bibliostatus-app --project bibliostatus-app --region europe-north1 --limit 50
```

(`gcloud config` may point at another project on your machine, so pass `--project`.)

## Rolling back

Send the traffic to the previous revision (every deploy makes one):

```bash
gcloud run revisions list --service bibliostatus-app --project bibliostatus-app --region europe-north1
gcloud run services update-traffic bibliostatus-app --project bibliostatus-app --region europe-north1 \
    --to-revisions=<previous-revision>=100
```

Then fix the problem on a branch, as usual. A rollback **pins** the traffic to that revision, so later deploys create new revisions that get no traffic until you send it back to the latest one:

```bash
gcloud run services update-traffic bibliostatus-app --project bibliostatus-app --region europe-north1 --to-latest
```

## Manual deployment

For a first setup or an emergency, `./deploy.sh` builds the image with Cloud Build and deploys it with the same settings (it creates the project and enables the APIs if they are missing). It keeps the service's existing secrets, but it skips the tests and the smoke test.

```bash
./deploy.sh
```

Prerequisites: the [gcloud CLI](https://cloud.google.com/sdk/docs/install) and a Google Cloud account with billing enabled.

## Local development with Docker

```bash
docker compose up --build
# Open http://localhost:8082
```

## Custom domain

Map a custom subdomain to the Cloud Run service:

```bash
gcloud beta run domain-mappings create \
    --service bibliostatus-app \
    --domain bibliostatus.youcanbeapirate.com \
    --region europe-north1
```

Then add a CNAME record in your DNS provider:

- Name: `bibliostatus`
- Value: `ghs.googlehosted.com`

SSL certificate provisioning takes ~15-30 minutes.

## Monitoring

- **Uptime and alert**: a Cloud Monitoring uptime check calls `/health` every 5 minutes, and an alert policy (severity Critical, so the e-mail subject starts with "[ALERT - Critical]") e-mails after 10 minutes of failure. `fixes/monitoring_setup.sh` creates them (it is not idempotent: running it again duplicates them). The alert e-mail was tested on 2026-10-24 with a temporary failing check; both the alert and the "resolved" e-mail arrived.
- **Other alerts**: the daily URL check e-mails when a library website is broken. There is no budget alert yet (it can only be created in the Cloud console).
- **Console**: [Cloud Run](https://console.cloud.google.com/run).

## Cost

Google Cloud Run has a generous free tier that covers personal use:

- 2 million requests/month
- 360,000 GB-seconds of memory
- 180,000 vCPU-seconds of compute

For a personal project with occasional use, this should be **completely free**. Artifact Registry keeps only recent images (`infra/artifact-registry-cleanup.json`).
