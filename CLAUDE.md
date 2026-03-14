# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BiblioStatus is a Shiny web app that displays real-time opening status of Finnish public libraries on an interactive map. Data is fetched daily from the Kirkanta API and stored in Turso (cloud SQLite) with SQLite file fallback.

## Common Commands

### Local Development
```bash
# With Docker (recommended)
docker compose up --build
# Open http://localhost:8082

# Or directly with R
renv::restore()
source("fetch_library_data.R")
shiny::runApp("app/")
```

### Data Pipeline
```bash
# Fetch schedules only (daily)
UPDATE_TYPE=schedules Rscript fetch_library_data.R

# Fetch both libraries and schedules (weekly)
UPDATE_TYPE=both Rscript fetch_library_data.R
```

### Deployment
```bash
./deploy.sh  # Deploy to Google Cloud Run
```

## Architecture

### Data Flow
1. **fetch_library_data.R** - Pulls data from Kirkanta API (v4):
   - Daily: schedules (opening hours) at 2 AM UTC
   - Weekly (Sunday): library metadata + services
   - Writes to Turso (primary) and `app/libraries.sqlite` (backup)

2. **Shiny App** (`app/`) reads from Turso, falls back to SQLite if unavailable

### Key Files
- `app/server.R` - Main server logic with reactive state management, map rendering, filter cascading
- `app/ui.R` - UI layout with map, sidebar filters, and Service Statistics tab
- `app/www/functions.R` - Database queries (Turso + SQLite fallback), distance calculations
- `app/modules/service_stats.R` - Service statistics Shiny module
- `R/turso.R` - Turso HTTP API wrapper (httr2-based)

### Database Schema
- `libraries` - Library metadata (id, name, coordinates, city, contact info)
- `schedules` - Opening hours by date (library_id, date, from_time, to_time, status_label)
- `library_services` - Normalized services (library_id, service_name)

### Reactive State (server.R)
- `committed_city/service/library` - Filter state shown on map (updated only by "Show on Map" button)
- Cascade observers update dropdown choices but NOT the map directly (prevents race conditions)
- `startup_city_set` - Tracks whether initial city was determined (geolocation or Helsinki fallback)

## Environment Variables

Required for Turso database access:
- `TURSO_DATABASE_URL` - Turso database URL (libsql:// or https://)
- `TURSO_AUTH_TOKEN` - Turso auth token

Alternatively, create `secret.R` or `app/secret.R` with these variables defined.

## GitHub Actions Workflows

- **fetch_data.yml** - Daily schedules (2 AM UTC), weekly full refresh (Sunday)
- **deploy_shiny_app.yml** - Auto-deploys to Cloud Run after data fetch
- **check_library_urls.yml** - Daily URL validation (3 AM UTC)

## Code Patterns

### Turso API Usage
```r
# Query (returns data frame)
turso_query("SELECT * FROM libraries WHERE city_name = ?", list("Helsinki"))

# Execute (INSERT/UPDATE/DELETE)
turso_execute("INSERT INTO libraries (...) VALUES (...)", list(...))
```

### Filter Cascade Design
City/service dropdowns update library choices but NOT each other to avoid bidirectional race conditions. The map only re-renders when `committed_*` reactive values change (via "Show on Map" button or startup).
