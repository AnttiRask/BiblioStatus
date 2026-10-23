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
   - Daily: schedules (opening hours) for a window of 7 days from today (Finnish date, `R/schedules.R`), requested at 2 AM UTC but GitHub starts the job hours late (06:47 to 07:09 UTC in October). The app reads today's rows, so with only today's day stored every library was unknown from midnight until the job ran; the window means yesterday's run already stored today
   - Weekly (Sunday): library metadata + services
   - Writes to Turso (primary) and `app/libraries.sqlite` (backup)

2. **Shiny App** (`app/`) reads from Turso, falls back to SQLite if unavailable

### Key Files
- `app/global.R` - Loaded once by Shiny (and by `tests/testthat.R`): packages, then `www/variables.R`, `www/strings.R`, `www/functions.R` and the service statistics module
- `app/server.R` - Session state (reactiveVals, reconnect seeding) and `server_parts`: the files below, parsed once when `server.R` loads and evaluated inside every session's `server()` call, in the order the observers must be created. Tests run `server` with `testServer()` (and change the working directory), so the parts must share the server function's environment and must not be found by a relative path at session time
- `app/server/data.R` (loading), `filters.R` (dropdown changes, startup city, clear buttons, Reset, the library detail panel selection), `map.R` (markers, Find Nearest), `panels.R` (sidebar details)
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
- The map follows `selection()` live (`libraries_on_map()` in `map.R` = `filter_libraries()` of the selection); there is no "Show on Map" button and no separate committed state. **The map is rendered once** (`output$map`, which waits for the startup city and `is_mobile`, and reads the selection and theme with `isolate()` so filter changes don't re-render it); later changes go through `leafletProxy("map")` calling the same `refresh_map()` (tiles replaced by layer id, markers, legend), and the view only moves when the set of libraries changes, so toggling dark mode keeps the user's zoom. A proxy message sent before the browser has built the map is dropped by leaflet, which is harmless because the render already used the current selection A summary line ("12 libraries · Espoo · Sauna") and a "Reset filters" link (back to the startup city, nothing else) sit under the dropdowns
- `startup_city_set` - Tracks whether initial city was determined (geolocation or Helsinki fallback)
- **Reconnects (`session$allowReconnect("force")`).** `TRUE` does nothing on Cloud Run: the Shiny client only reconnects if the host (Shiny Server, Posit Connect) allows it too, so a dropped websocket (Cloud Run closes it at `--timeout`, 3600 s at most) greys the page out. `"force"` makes the client reconnect anyway. Tested locally by closing the socket (`Shiny.shinyapp.$socket.close()`): back in about 1.5 s, the city and library dropdowns keep their values. **The startup inputs ARE sent again to the new session** (seen in a real browser on 2026-10-23: about 1 s after the seeding the startup observer fired and moved the city to Helsinki, so the map no longer matched the dropdowns). `set_city_from_startup()` therefore only applies when no city is selected yet. The browser console shows about 18 "output ... is in an unexpected state" errors on every forced reconnect (`geolocation_error_ui`, `nearest_libraries_ui`, `library_services`, `map`, and now `filter_summary`): a Shiny client quirk that the live version before the live-map change shows too; the outputs still update afterwards. The server can't resume the old session, so a **new one starts and the browser re-sends its inputs**; every reactiveVal above starts empty again. **Seeding after a reconnect:** the dropdown observers use `ignoreInit = TRUE`, and the startup inputs are one-shot, so a reconnected session used to start with an empty selection: the map showed the whole country even though the dropdowns still showed a library or service. A one-time observer (priority 10, `once = TRUE`) next to the `selection` declaration now copies the dropdowns' first values into `selection()`, and the map and the library detail panel follow it. On a normal page load the first values are empty and nothing changes. Tests: the three `reconnect` / `normal page load` tests in `test-server-filters.R` (the first `setInputs()` call carries all the values, like the re-send; don't flush before it). Checked in a browser (with the old "Show on Map" design) by closing the socket: startup city only, a library (map and detail panel), and a service plus city all came back identical; **not yet re-checked after the live-map change**. Keep observers idempotent: no paid API call or write behind an input that fires again on a fresh session.

## Environment Variables

Required for Turso database access:
- `TURSO_DATABASE_URL` - Turso database URL (libsql:// or https://)
- `TURSO_AUTH_TOKEN` - Turso auth token

Alternatively, create `secret.R` or `app/secret.R` with these variables defined.

There is no map-tile key: the basemap is Esri's keyless World Light/Dark Gray canvas. (`CARTO_API_KEY` was removed on 2026-10-17: the Carto trial ended, its dashboard became unreachable, and a key that is visible in tile URLs and can be neither restricted nor rotated is a liability. The `carto-api-key` Secret Manager secret was disabled and the `CARTO_API_KEY` GitHub secret deleted on 2026-10-17; no app uses either.)

## GitHub Actions Workflows

- **fetch_data.yml** - Daily schedules (2 AM UTC), weekly full refresh (Sunday)
- **tests.yml** - Runs the testthat suite on the locked packages (push, pull request, manual); the deploy calls it first
- **deploy_shiny_app.yml** - Deploys to Cloud Run when tests pass, on pushes that change the app or build files (not the nightly database commit), weekly (Monday 04:00 UTC, refreshes the SQLite fallback in the image) and on demand; labels the revision with the commit and smoke tests it. Turso is the primary data source, so the nightly data fetch no longer redeploys. The SQLite fallback holds the 7-day window written by the last fetch, so an old image shows opening hours for up to a week during a Turso outage
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

### Theme (light / dark)
Light is the default; `input_dark_mode(mode = "light")` toggles. `app_theme()` (in `functions.R`) is an ordinary light bslib theme with dark mode added on top (`body-bg-dark` = the brand dark `#191414`, lighter red links), like FillariStatus; the map follows the same toggle (`is_dark()`), so the page and the map are always in the same mode. **Don't set `bg`/`fg` in `bs_theme()`**: bslib treats them as the LIGHT mode, and setting them to the dark brand colours (which this app did until 2026-10-23) made the page dark in "light" mode and, inverted, light in "dark" mode, opposite to the map. Brand colours are in `brand_colours` (`variables.R`); text in the brand red uses `var(--brand-accent)` in CSS and inline styles (the brand red on the light page, the lighter red on the dark one: the brand red is only 3.1:1 on `#191414`). Buttons with white text keep the brand red. `test-theme.R` guards the theme and keeps the CSS accent colours in sync with `brand_colours`.

### Filter dropdown rules
Defined in `app/www/filter_logic.R` and used by `app/server/filters.R`; the plan and the reasoning are in `bibliostatus-refactor-plan.md` (section 1).
- The city list is always complete (a service or a library never narrows it). The service list depends on the city only, the library list on the city and the service. Cities and services show how many libraries are behind them (a city's count is all of its libraries).
- Picking a library sets its city. Picking a city or service that the picked library doesn't match clears the library, and picking a city the selected service isn't offered in clears the service; each shows a notice. Note that many libraries have no service data at all (139 of 719, e.g. all of Tampere), so a service filter can legitimately give few cities' libraries. A value that isn't offered is refused and the dropdown is sent back to what the server holds.
- Every change goes through `apply_filter_change()`; `push_dropdowns()` sends only the lists/selections that changed. The browser echoing a value the server just sent changes nothing (`changed = FALSE`), which is why there is no cascade and no race. Don't add observers that write one dropdown from another.
- The map follows `selection()` directly, so the x buttons, the startup city and Reset need no extra bookkeeping. The first map is drawn once `startup_city_set()` is TRUE (it is part of the render trigger).
- `testServer()` can't read back `updateSelectInput()` calls; the tests record them by shadowing the functions in the global environment (`record_dropdown_updates()` in `test-server-filters.R`).
