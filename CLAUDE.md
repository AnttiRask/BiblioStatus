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
- `app/global.R` - Loaded once by Shiny (and by `tests/testthat.R`): packages, then `www/variables.R`, `www/strings.R`, `www/functions.R` and the service statistics module
- `app/server.R` - Session state (reactiveVals, reconnect seeding) and `server_parts`: the files below, parsed once when `server.R` loads and evaluated inside every session's `server()` call, in the order the observers must be created. Tests run `server` with `testServer()` (and change the working directory), so the parts must share the server function's environment and must not be found by a relative path at session time
- `app/server/data.R` (loading), `filters.R` (dropdown cascades, startup city, clear buttons, "Show on Map"), `map.R` (markers, Find Nearest), `panels.R` (sidebar details)
- `app/ui.R` - UI layout with map, sidebar filters, and Service Statistics tab
- `app/www/variables.R` - Colours, map tuning constants, footer app list, geolocation timings; `strings.R` - user-facing text of `ui.R`/`server.R` (`txt$...`); `app.js` - client-side script (config comes from `geo_config` through `window.BIBLIO_CONFIG`); `asset()` in `functions.R` cache-busts it
- `app/www/functions.R` - Database queries (Turso + SQLite fallback), distance calculations
- `app/modules/service_stats.R` - Service statistics Shiny module
- `R/turso.R` - Turso HTTP API wrapper (httr2-based)

### Database Schema
- `libraries` - Library metadata (id, name, coordinates, city, contact info)
- `schedules` - Opening hours by date (library_id, date, from_time, to_time, status_label)
- `library_services` - Normalized services (library_id, service_name)

### Reactive State (server.R)
- `selection()` - what the three dropdowns hold: `list(city, service, library)`, `""` = all. The single source of truth for the dropdowns; read it instead of `input$city_filter` etc., which can lag behind what the server just sent. The rules (what each list offers, what a change does to the others, the notices) are in `app/www/filter_logic.R` (pure functions, tested in `test-filter-logic.R`); `app/server/filters.R` connects them to the inputs
- `committed_city/service/library` - Filter state shown on map (updated by the "Show on Map" button, the x buttons and the startup city, never by changing a dropdown)
- `startup_city_set` - Tracks whether initial city was determined (geolocation or Helsinki fallback)
- **Reconnects (`session$allowReconnect("force")`).** `TRUE` does nothing on Cloud Run: the Shiny client only reconnects if the host (Shiny Server, Posit Connect) allows it too, so a dropped websocket (Cloud Run closes it at `--timeout`, 3600 s at most) greys the page out. `"force"` makes the client reconnect anyway. Tested locally by closing the socket (`Shiny.shinyapp.$socket.close()`): back in about 1.5 s, no errors, the city and library dropdowns keep their values, and the startup observers can't reset the city (the startup inputs are one-shot `priority: "event"` inputs and are not re-sent). The server can't resume the old session, so a **new one starts and the browser re-sends its inputs**; every reactiveVal above starts empty again. **Seeding after a reconnect:** the dropdown observers use `ignoreInit = TRUE`, and the startup inputs are one-shot, so a reconnected session used to start with an empty selection and an empty `committed_city`: the map showed the whole city (or country) even though the dropdowns still showed a committed library or service. A one-time observer (priority 10, `once = TRUE`) next to the `selection` declaration now copies the dropdowns' first values into `selection()`, and into `committed_city` if the startup observers did not set it; the "Show on Map" observer, which re-fires with the re-sent click count, then restores the committed library and service. On a normal page load the first values are empty and nothing changes. Tests: the three `reconnect` / `normal page load` tests in `test-server-filters.R` (the first `setInputs()` call carries all the values, like the re-send; don't flush before it). Checked in a browser by closing the socket: startup city only, a committed library (map and detail panel), and a committed service plus city all come back identical. Keep observers idempotent: no paid API call or write behind an input that fires again on a fresh session.

## Environment Variables

Required for Turso database access:
- `TURSO_DATABASE_URL` - Turso database URL (libsql:// or https://)
- `TURSO_AUTH_TOKEN` - Turso auth token

Alternatively, create `secret.R` or `app/secret.R` with these variables defined.

There is no map-tile key: the basemap is Esri's keyless World Light/Dark Gray canvas. (`CARTO_API_KEY` was removed on 2026-10-17: the Carto trial ended, its dashboard became unreachable, and a key that is visible in tile URLs and can be neither restricted nor rotated is a liability. The `carto-api-key` Secret Manager secret was disabled and the `CARTO_API_KEY` GitHub secret deleted on 2026-10-17; no app uses either.)

## GitHub Actions Workflows

- **fetch_data.yml** - Daily schedules (2 AM UTC), weekly full refresh (Sunday)
- **tests.yml** - Runs the testthat suite on the locked packages (push, pull request, manual); the deploy calls it first
- **deploy_shiny_app.yml** - Deploys to Cloud Run when tests pass, on pushes that change the app or build files (not the nightly database commit), weekly (Monday 04:00 UTC, refreshes the SQLite fallback in the image) and on demand; labels the revision with the commit and smoke tests it. Turso is the primary data source, so the nightly data fetch no longer redeploys. The SQLite fallback holds one day of schedules, so an old image shows no opening hours during a Turso outage
- **check_library_urls.yml** - Daily URL validation (3 AM UTC)

## Code Patterns

### Turso API Usage
```r
# Query (returns data frame)
turso_query("SELECT * FROM libraries WHERE city_name = ?", list("Helsinki"))

# Execute (INSERT/UPDATE/DELETE)
turso_execute("INSERT INTO libraries (...) VALUES (...)", list(...))
```

### Map tiles
`add_basemap(map, dark)` in `app/www/functions.R` adds the Esri base layer (with the attribution) plus a labels layer; `map_tile_urls()` builds the `{z}/{y}/{x}` URLs (Esri's order, not Carto's `{z}/{x}/{y}`). Gotchas:
- **Attribution must be `addTiles()`'s own `attribution` argument.** `addTiles()` overwrites `options$attribution` with it, so one passed through `tileOptions()` is silently dropped (the map showed only "Leaflet" for a long time).
- **Real tiles stop at zoom 16.** From 17 on Esri serves a grey "Map data not yet available" tile, so tile requests are capped at 16 (`map_tile_max_native_zoom`) and both `fitBounds()` calls pass `maxZoom = 16`.
- **Dark mode (fixed 2026-10-17):** `bslib::input_dark_mode()` reports the string `"dark"`/`"light"`, and the map used to test `isTRUE(input$dark_mode)`, which is never TRUE for a string, so the map's tiles and marker colours never went dark (introduced in `0242f04`, when `if (input$dark_mode)` was wrapped in `isTRUE()` to stop it erroring). Use the `is_dark()` reactive in `server.R`. Regression tests are in `test-server-filters.R`.
- Tile providers can answer HTTP 200 with a placeholder; check tile content, not the status code.

### Filter dropdown rules
Defined in `app/www/filter_logic.R` and used by `app/server/filters.R`; the plan and the reasoning are in `bibliostatus-refactor-plan.md` (section 1).
- The city list depends on the service only, the service list on the city only, the library list on both; a picked library narrows neither of the other lists. Cities and services show how many libraries are behind them.
- Picking a library sets its city. Picking a city or service that the picked library doesn't match clears the library and shows a notice. A value that isn't offered is refused and the dropdown is sent back to what the server holds.
- Every change goes through `apply_filter_change()`; `push_dropdowns()` sends only the lists/selections that changed. The browser echoing a value the server just sent changes nothing (`changed = FALSE`), which is why there is no cascade and no race. Don't add observers that write one dropdown from another.
- The map follows `committed_*`: "Show on Map" commits `selection()`, the x buttons commit their clear immediately, the startup city commits the city. (Making the map follow the dropdowns live is a later step of the plan.)
- `testServer()` can't read back `updateSelectInput()` calls; the tests record them by shadowing the functions in the global environment (`record_dropdown_updates()` in `test-server-filters.R`).
