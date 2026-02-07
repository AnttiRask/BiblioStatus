# Deploying BiblioStatus to Google Cloud Run

## Prerequisites

1. [Google Cloud SDK (gcloud CLI)](https://cloud.google.com/sdk/docs/install) installed
2. A Google Cloud account with billing enabled

## Local Development with Docker

1. Build and run:

   ```bash
   docker compose up --build
   ```

2. Open http://localhost:8082

## Deploy to Google Cloud Run

### Option 1: Using deploy.sh (recommended)

```bash
./deploy.sh
```

The script will:

- Create the GCP project `bibliostatus-app` if it doesn't exist
- Enable required APIs (Cloud Build, Cloud Run, Artifact Registry)
- Deploy to Cloud Run in `europe-north1`

### Option 2: Manual deployment

1. Set the project and enable APIs:

   ```bash
   gcloud config set project bibliostatus-app
   gcloud services enable cloudbuild.googleapis.com run.googleapis.com artifactregistry.googleapis.com
   ```

2. Deploy:

   ```bash
   gcloud run deploy bibliostatus-app \
       --source . \
       --platform managed \
       --region europe-north1 \
       --allow-unauthenticated \
       --memory 1Gi \
       --timeout 300
   ```

## Custom Domain

Map your custom subdomain to the Cloud Run service:

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

## Cost

Google Cloud Run has a generous free tier that covers personal use:

- 2 million requests/month
- 360,000 GB-seconds of memory
- 180,000 vCPU-seconds of compute

For a personal project with occasional use, this should be **completely free**.

## Updating the App

To deploy updates:

```bash
gcloud run deploy bibliostatus-app --source .
```

## Monitoring

View logs:

```bash
gcloud run logs read bibliostatus-app --region europe-north1
```

View in console:

- [Cloud Run Console](https://console.cloud.google.com/run)
