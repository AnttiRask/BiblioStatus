# 📚 BiblioStatus

**BiblioStatus** is a web app that shows the real-time opening status of Finnish public libraries on a map.

## 🔍 Features

**The map**

- 🌍 Interactive map with open / self-service / closed / closed-all-day statuses colour-coded, **recomputed every minute** from the day's opening hours, so a library that opens while the page is open changes colour without a reload
- 📍 **Find Nearest Open Library** - uses GPS to find the 3 (phone) or 5 (desktop) closest open libraries with distances; respects a selected service ("the nearest open library with a sauna")
- 🌗 Light and dark mode (light by default; the map follows)
- 📱 Mobile-optimized layout with responsive sidebar and touch controls

**Finding a library**

- 🔎 **Search All Libraries** - type part of a name and pick a library in any city; the map jumps to it
- 🏢 City / municipality filter, including **All Cities** to see every library at once
- 🏷️ **Service filter** - 240+ services; the service and library lists follow the city (and service) you picked, and a short notice says so when a choice no longer fits and is cleared
- 🔗 **Shareable links** - the filters are in the page address (`?city=Espoo&service=Sauna&library=123`), so a link restores a view and a reload keeps it
- 📊 **Service Statistics** tab - how common each service is, per city, as a chart and a table

**A library's details**

- 📅 Complete daily schedule (e.g. "10:00-14:00 Open, 14:00-20:00 Self-service"), with the current period marked
- 📞 Phone and e-mail links (only for values that look like a phone number or address), 🔗 the library's website, and 🗺️ one-click Google Maps directions
- 💎 Services listed for the library

**Reliability**

- 📦 Data from the Kirkanta API is updated nightly via GitHub Actions and stored in Turso (cloud SQLite) with a SQLite backup in the app
- 🛟 If the database is unreachable the page says so: it shows the last good data (marked with its time), the nightly backup, or a plain message, instead of failing silently
- 🩺 `GET /health` for uptime monitoring, with a Cloud Monitoring check and an e-mail alert
- ✅ Automated URL monitoring with an e-mail alert for broken links

## 📸 Screenshot

![](screenshot.png)

## 🚀 Live App

👉 [Try it here!](https://bibliostatus.youcanbeapirate.com)

## 🛠️ Project Structure

```bash
fetch_library_data.R        # The data pipeline (Kirkanta API v4 -> Turso + SQLite backup)
check_library_urls.R        # Validates all library URLs
R/                          # Pipeline code the app shares or tests
├── turso.R                 # Turso HTTP API: reads (with timeout and retry), all-or-nothing writes
├── schedules.R             # The 7-day window, parsing the API's schedules, how the window is written
├── library_write.R         # Replacing the libraries and services in one transaction
├── coordinates.R           # Which coordinates to believe (override > API > last good snapshot)
└── backfill_historical_data.R  # Backfill historical schedules
data/                       # Manual corrections and the coordinate snapshot (CSV)
├── library_url_overrides.csv, library_coordinate_overrides.csv, library_exclusions.csv
└── library_coordinates.csv # Last good coordinates of every library (kept up to date by the weekly run)
app/
├── run.R                   # Entry point: security headers, /health, host and port
├── global.R, server.R, ui.R
├── server/                 # data (loading, reloading), filters, url (the address), map, panels
├── modules/service_stats.R # The Service Statistics tab
├── libraries.sqlite        # SQLite backup (written by the pipeline)
└── www/
    ├── functions.R         # Database queries, status calculation, map drawing, popups
    ├── data_layer.R        # get_app_data(): never throws, shared cache, stale/backup states
    ├── filter_logic.R      # The dropdown rules (no Shiny in it), the search box, the address
    ├── health.R, security.R # /health and the security headers (including the CSP)
    ├── strings.R           # All user-facing text
    ├── variables.R         # Colours, map settings, cache and reload times
    ├── app.js, mode-toggle.js, styles.css
tests/testthat/             # The test suite (about 1,500 expectations)
.github/workflows/          # tests, fetch_data, check_library_urls, deploy_shiny_app
infra/, fixes/              # Artifact Registry cleanup policy, the monitoring setup script
schema.sql, Dockerfile, docker-compose.yml, deploy.sh, renv.lock
```

`CLAUDE.md` describes how the pieces fit together (for people and for Claude Code), and `bibliostatus-refactor-plan.md` is the record of the 2026-10 refactor.

## 🔄 Data Pipeline

**Daily schedule update** (2:00 AM UTC; GitHub often starts the job a few hours late):

1. GitHub Actions runs `fetch_library_data.R` in "schedules" mode
2. Fetches **seven days of opening hours** (today and the six days after, by the Finnish date) from the [Kirkanta API (v4)](https://api.kirjastot.fi/) - the days ahead are already stored when midnight comes, so there is a status from the first minute of the day
3. Replaces that window in Turso **a group of libraries at a time, each group in one transaction**, so a page loaded meanwhile always sees a library's old hours or its new ones, never none; history before today is kept
4. Writes the whole window to `libraries.sqlite` as the backup

**Weekly library update** (Sunday 2:00 AM UTC):

1. Runs `fetch_library_data.R` in "both" mode
2. Fetches library metadata (names, coordinates, URLs, contact info, services)
3. Applies the manual corrections in `data/` (100+ URL fixes, a few coordinate fixes, libraries without an address of their own left out)
4. **Coordinates** come from the manual overrides, else the API if they can be in Finland, else the last good ones in `data/library_coordinates.csv` (the API once gave 0, 0 for a library); the file is kept current by this run
5. Normalizes the services to the `library_services` table (10,000+ records, 240+ unique services)
6. Replaces the libraries and services in Turso **in one transaction**, and refuses a fetch with fewer than half of the stored libraries

## 🧠 How the App Gets Its Data

- `get_app_data()` reads Turso (8-second timeout, one retry) and falls back to `libraries.sqlite`; it never throws and says where the data came from
- All visitors share one read for 5 minutes; if Turso fails, the last good read is shown (marked stale) for up to 3 hours, and a failed read isn't repeated for 30 seconds
- A page that stays open reloads its data every 10 minutes and recomputes the statuses every minute
- The page shows a short notice when it is on the backup or older data, when part of the data is missing, or when nothing could be loaded

## ✅ Data Quality & URL Monitoring

All library website URLs are checked automatically every day at 3:00 AM UTC. If any is broken, an e-mail alert is sent and the URL is investigated and corrected (the fixes live in `data/library_url_overrides.csv`); when all are fine, nothing is sent.

## 🩺 Monitoring & Security

- `GET /health` answers `ok`, or a 503 with a short reason (no data, no opening hours for today, the nightly update lagging, only the backup available)
- A Google Cloud Monitoring uptime check calls it every 5 minutes and e-mails a Critical alert after 10 minutes of failure (`fixes/monitoring_setup.sh`)
- Security headers on every page, including an **enforced Content-Security-Policy** that allows only the app's own origin, the map tiles and the font stylesheet
- The app only ever reads from the database (local development included); the pipeline is the only writer

## 🔐 Deployment

The app runs as a Docker container on Google Cloud Run. Every change goes through a pull request whose tests must pass; merging to `main` deploys it (the build takes about 8 minutes) through a GitHub Actions workflow with keyless Google Cloud login. See [DEPLOY.md](DEPLOY.md) for how it works and for manual deployment.

## 🧪 Local Development

With Docker:

```bash
docker compose up --build
# Open http://localhost:8082
```

Or directly with R:

```r
renv::restore()
shiny::runApp("app/")
```

The app needs the Turso credentials: put `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` in a git-ignored `.Renviron` in the project folder (see [CLAUDE.md](CLAUDE.md)). Without them it uses `app/libraries.sqlite`.

**Tests** (they never touch the real database):

```bash
Rscript tests/testthat.R
```

The same suite runs on every pull request and gates the deploy.

## 📦 Required R Packages

The versions are locked in `renv.lock` (R 4.5.2).

- [bslib](https://rstudio.github.io/bslib/) - Bootstrap 5 theming and layout
- [dplyr](https://dplyr.tidyverse.org/) - Data manipulation
- [DT](https://rstudio.github.io/DT/) - Interactive data tables
- [ggplot2](https://ggplot2.tidyverse.org/) - Statistical graphics
- [here](https://here.r-lib.org/) - Path management
- [httr](https://httr.r-lib.org/) and [httr2](https://httr2.r-lib.org/) - Kirkanta API and Turso HTTP API clients
- [jsonlite](https://github.com/jeroen/jsonlite) - JSON parsing
- [leaflet](https://rstudio.github.io/leaflet/) - Interactive maps
- [purrr](https://purrr.tidyverse.org/) - Functional programming
- [RSQLite](https://rsqlite.r-dbi.org/) - SQLite database interface
- [shiny](https://shiny.posit.co/r/getstarted/shiny-basics/lesson1/) - Web framework
- [shinyjs](https://deanattali.com/shinyjs/) - JavaScript operations
- [stringr](https://stringr.tidyverse.org/) - String manipulation
- [tidyr](https://tidyr.tidyverse.org/) - Data tidying
- [testthat](https://testthat.r-lib.org/) and [withr](https://withr.r-lib.org/) - Tests

## 🗺️ Map Tiles

The basemap is Esri's World Light / Dark Gray canvas with a labels layer. It needs no API key, and the attribution ("Tiles © Esri — Esri, HERE, Garmin, © OpenStreetMap contributors, and the GIS user community") is shown on the map. The tiles are real only up to zoom 16, so tile requests are capped there and scaled up for closer views. (The app used Carto tiles with an API key until 2026-10-17.)

## 📄 License

- [MIT](https://opensource.org/license/mit)
