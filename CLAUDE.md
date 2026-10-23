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

Locally they live in the git-ignored `.Renviron` in the repo root (`TURSO_DATABASE_URL=...`, one per line, no quotes): R reads it at startup when started from the repo root, and `docker-compose.yml` passes it to the container with `env_file`. `secret.R` is no longer read (removed 2026-10-23).

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

### Health check (`GET /health`)
`app/www/health.R`, wired up in `run.R` (`with_security_headers(with_health_check(shinyAppDir(".")))`, so the answer carries the security headers): 200 and `ok`, or 503 and a short reason without error details, for an uptime monitor. A page that answers 200 on `/` proves nothing: the shell loads while Turso is down (the SQLite backup hides that from visitors) and while the nightly update fails. Reasons: `unavailable` (neither Turso nor the backup can be read), `empty` (no libraries), `no_schedules` (no opening hours for today: every library would read "no status data"), `stale` (the newest stored opening hours are less than `health_min_days_ahead` = 2 days ahead; the nightly job stores a week, so this is the early warning, days before `no_schedules`), `degraded` (the SQLite backup is in use because Turso fails). `health_probe()` reads Turso, then the backup; `health_status()` is pure; answers are cached for 60 s (`health_cache_seconds`) so a monitor checking from several regions doesn't hammer Turso. The deploy's smoke test deliberately checks only `/`: a data problem shouldn't turn a deploy red. **The uptime check and alert policy in Cloud Monitoring are not created yet** (they need the owner's approval).

**Local development reads production Turso.** The git-ignored `.Renviron` holds the Turso credentials and `docker-compose.yml` hands it to the container (`env_file`; after changing it, recreate the container with `docker compose up -d`, a restart keeps the old values), so the app (and `/health`) read the real database. The app only ever reads from Turso; the pipeline is the only writer.

### Opening status over time
The status of a library is **recomputed every minute**, not once per page. `refresh_data()` (`server/data.R`) loads the libraries and the schedule rows of today and tomorrow once per session (`schedule_dates_to_load()`, so a page left open past midnight can switch day without loading again); `refresh_statuses()` then computes `library_data()` from them and the Finnish clock (`compute_library_statuses()` in `functions.R`, pure and tested in `test-statuses.R`), once at load and then a little after every full minute (`ms_to_next_minute()`). `library_data()` is only replaced when something actually changed, so a minute without a change doesn't redraw the map. The details of a library that is open get the new status too (`selected_library` is refreshed from `library_data()`), and the "now" mark in the day's schedule follows `status_clock()`. Don't make anything that opens the details panel depend on `library_data()` (it changes whenever any status changes): the library-selection observer in `filters.R` reacts to `selection()$library` only. The clock is `helsinki_time_now()` / `helsinki_today()`, which tests replace (`with_clock()` in `test-server-filters.R`; `session$elapse()` moves the timer).

### Find Nearest
`nearest_open_libraries()` (`functions.R`, tested in `test-nearest.R`): the open or self-service libraries closest to the user, closest first. With a service selected, only libraries offering it count, and the list's heading says so ("Nearest open libraries offering Sauna:"); when none qualifies the notice names the service. The city and library filters deliberately don't apply (what is nearest depends on where the user is). Find Nearest never touches the dropdowns. The result belongs to the city shown and the service it was searched with, so changing either (or clearing, Reset) clears it (`handle_user_change()`, `Reset`); press the button again.

### Filters in the page address
The selection is in the address (`?city=Espoo&service=Sauna&library=123`; `selection_to_query()` / `selection_from_query()` in `filter_logic.R`, wired up in `app/server/url.R`). **A link restores a selection:** once, when the first data has loaded, the address is read and its values are applied in the order city, service, library through the same rules as the dropdowns, on top of the current selection; a value that doesn't exist or doesn't fit (a made-up city, a service the city doesn't have, a library in another city) is left out, with a notice, instead of giving an empty map. A link with a city decides the starting city (`startup_city_set(TRUE)`), so the map doesn't wait for the location. **The address follows the selection** (`updateQueryString(mode = "replace")`, no history entry per change); it is not written until the link has been read (`url_ready`), so a slow or failed data load can't wipe an incoming link. The page address survives a reconnect, so a reconnected session starts from the same selection; the older seeding observer (first dropdown values into `selection()`) is still there as a fallback. `testServer()`'s session has a fixed fake query string, so the server reads it through `url_search_of()`, which tests replace (`with_address()` in `test-server-filters.R`, which also feeds fixture data through the fetch functions).

### Filter dropdown rules
Defined in `app/www/filter_logic.R` and used by `app/server/filters.R`; the plan and the reasoning are in `bibliostatus-refactor-plan.md` (section 1).
- The city list is always complete (a service or a library never narrows it). The service list depends on the city only, the library list on the city and the service. Cities and services show how many libraries are behind them (a city's count is all of its libraries).
- Picking a library sets its city. Picking a city or service that the picked library doesn't match clears the library, and picking a city the selected service isn't offered in clears the service; each shows a notice. Note that many libraries have no service data at all (139 of 719, e.g. all of Tampere), so a service filter can legitimately give few cities' libraries. A value that isn't offered is refused and the dropdown is sent back to what the server holds.
- Every change goes through `apply_filter_change()`; `push_dropdowns()` sends only the lists/selections that changed. The browser echoing a value the server just sent changes nothing (`changed = FALSE`), which is why there is no cascade and no race. Don't add observers that write one dropdown from another.
- The map follows `selection()` directly, so the x buttons, the startup city and Reset need no extra bookkeeping. The first map is drawn once `startup_city_set()` is TRUE (it is part of the render trigger).
- `testServer()` can't read back `updateSelectInput()` calls; the tests record them by shadowing the functions in the global environment (`record_dropdown_updates()` in `test-server-filters.R`).
