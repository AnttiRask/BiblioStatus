# BiblioStatus — Refactor Plan

> Bring BiblioStatus in line with how FillariStatus, Gallery of the Day and TuneTeller now work (`fillaristatus-plan.md`, `gallery-of-the-day-refactor-plan.md`, `tuneteller-refactor-plan.md`), and **fix the filter dropdowns properly instead of patching them again**.
>
> **For Claude Code:** read this whole file first. Phase 1 is the dropdown redesign and is the part the user cares most about. Every change is checked with the user before it is committed, pushed or deployed. Phase 4 touches cloud resources and GitHub settings: each step needs approval. Pushes that change the build files redeploy the app, so batch them. Never print secrets.

*Written 2026-10-22; status updated 2026-10-23 (Phase 4 done, see section 4 and the table below). Based on reading the three sibling plans and the current `app/server.R`, `app/ui.R`, `app/www/functions.R`, `app/run.R`, `Dockerfile`, the three workflows and `tests/testthat/`. Nothing here has been run or changed yet. Items marked (verify) are suspicions from reading the code, not confirmed behaviour.*

---

## 0. Where things stand

**Repo state:** on 2026-10-22 local `main` was 3 commits behind GitHub (nightly "Update database" commits only); it was pulled with `git pull --rebase --autostash` (the pending `full-fix-plan.md` deletion blocks a plain rebase). Pull before editing; the bot commits every night. `full-fix-plan.md` is still deleted in the working tree (moved to untracked `fixes/full-fix-plan.md`) and the sibling plan files are untracked; decide whether to commit them (see 5.4).

**Progress (2026-10-23, end of day):** Phase 4 (CI/CD and infrastructure) and Phase 2 (structure) are **done and deployed**. Phase 1 steps (a) pure rules, (b) dropdowns on the rules, (c) live map are **live**. The week of schedules (Phase 3 item 8) is **live**, and the first week-long fetch ran against production (8,822 rows, 7 dates, all 719 libraries, 7 Unknown rows). Phase 1 (d) `leafletProxy` split, (e) filters in the URL and the theme fix (page and map in the same mode, light by default) are also live; (f) Find Nearest respects the service filter is the last Phase 1 step. Phase 3 item 3 (stale open/closed status in a long session) is built on `feat/live-status`. Still open: Phase 3 leftovers (`/health` + uptime alert, shared cache and never-throwing data layer, popup/stats text into `strings.R`); small items (unused `terra`/`raster` in `renv.lock`, the budget alert, Artifact Registry size check). In the table below, rows marked *done* were gaps when this plan was written. Lessons from the day are in the memory note `bibliostatus-ci-lessons` (apt GDAL stalls, the concurrency collision, GitHub cron running hours late, startup events re-sent after a reconnect).

**What the siblings did that BiblioStatus has not:**

| Practice | FillariStatus | Gallery | TuneTeller | BiblioStatus now |
|---|---|---|---|---|
| `global.R`, `variables.R`, `strings.R` split | yes | yes | yes | no: libraries and 14 constants at the top of `server.R`, UI text inline, a 140-line inline JS block in `ui.R` |
| JS in its own file | yes | yes (`lightbox.js`) | n/a | no |
| Never-throwing data layer with explicit states (ok / stale / error / empty) | yes | yes | yes | partly: Turso→SQLite fallback, but an empty or failed read just gives a blank or all-grey map |
| Shared server-side cache across sessions | yes (60 s) | yes (5 min) | n/a | no: every session runs three Turso queries on load |
| `/health` + uptime alert | no | yes | no | no |
| Tests in CI, gating the deploy | yes (in workflow) | `tests.yml` | `tests.yml` | *done 2026-10-22*: `tests.yml` (123 expectations, R 4.5.2 from the lock), the deploy needs it |
| Deploy smoke test (checks `git-sha` label) | yes | yes | yes | *done*: label + `GET /` = 200 (`/health` check waits for Phase 3.5) |
| Actions pinned to SHAs, minimal `permissions` | yes | yes | yes | *done*: all pinned; `id-token` only on the deploy job; `fetch_data.yml` keeps `contents: write` (single job that commits the database) |
| Keyless deploy, dedicated runtime account, no `roles/editor` | yes | yes | yes | yes (done 2026-10-18) |
| Security headers | yes | yes | yes | yes (`app/www/security.R`) |
| Reconnect (`allowReconnect("force")`) | yes | considered | no | yes, plus the seeding hack |
| Artifact Registry cleanup + budget alert | yes | yes | yes | cleanup policy *done 2026-10-22* (the repo held 344 images / 138.8 GB with none); budget alert unverified |

BiblioStatus is ahead of the others in one thing only: it has the most complicated reactive logic, and that is where its remaining problems are.

---

## 1. Phase 1 — redesign the filter dropdowns (the main job)

### 1.1 What is wrong today (read from `app/server.R`)

The user's report ("doesn't work intuitively, even after the earlier fixes") matches what the code does. The previous plans (`fixes/full-fix-plan.md`, Plan 1) fixed individual symptoms; the structure that produces them is still there.

1. **Two-stage model the user cannot see.** A dropdown change does not change the map. The map follows `committed_*`, which only changes on "Show on Map" and at startup. But the **× buttons commit immediately** (`clear_library`, `clear_service`), the **city dropdown changes silently reset other dropdowns**, and the **startup city is committed without being "pressed"**. So the rule is "picking changes nothing, clearing changes everything", which nobody can guess.
2. **The three dropdowns are cross-wired, and not symmetrically.**
   - city → library choices, service choices, and **resets** library (unless it is still valid) and nearest-results, user location and selected library.
   - service → library choices, and **always resets the library to "All"**, even when the picked library offers that service (`server.R:351`).
   - library → **sets the city** (the reverse direction the header comment claims was removed), and **narrows the service list to that one library's services**, then resets the service if it is not among them.
   - Nothing narrows the **city** list. Pick a service offered in 3 cities and the city list still shows all 300; pick one of the 297 others and the service is silently thrown away.
3. **Silent resets.** A selection disappears with no message when another dropdown changes. The user sees "I picked X and it went back to All". **Confirmed bug, found by the user on 2026-10-23 and fixed separately:** with a service selected, changing to a city that doesn't offer it left the library dropdown empty, because the city observer built the library list with the old service and only then reset the service. Reproduced by recording what the observer sends (the timing of browser automation was too unreliable to show it). Pre-existing, not from Phase 2. The new rules make the case impossible (the city list only offers cities that have the selected service).
4. **Server-written inputs read back.** `updateSelectInput()` / `updateSelectizeInput()` write to the browser and the browser echoes the value back to `input$*` later, which re-fires the other observers. The code works around this with `pending_service`, `pending_library`, `isolate(input$...)` reads, a "self-heal" branch in the map observer, a once-only seeding observer for reconnects, and `ignoreInit` flags. That is five workarounds for one design problem, and `testServer()` cannot test the round trip (noted in `test-server-filters.R`), so the part that breaks is exactly the part that is untested.
5. **Library choices are re-sent on every change** (`server = TRUE`, ~700 choices) and the label for "no selection" is an empty-string choice ("All Libraries") that selectize also uses as placeholder.
6. **Find Nearest ignores the filters** and replaces the map markers through a second code path (`update_map_for_nearest`) that the filter observer then overwrites on its next run; the city observer clears the nearest results as a side effect.

### 1.2 Target behaviour (proposed; confirm with the user before building)

One mental model: **three filters that narrow the map, live.**

- **Live apply.** The map follows the dropdowns as they change (debounced about 300 ms). "Show on Map" goes away. A line under the filters says what is showing: "12 libraries · Espoo · Sauna", and a **Reset filters** link returns to the post-startup state (startup city, nothing else).
  *Alternative if the user wants to keep the button:* keep it, but then **every** path, including ×, startup and reset, waits for it, and the button turns into "Apply (3 changes)" so the pending state is visible. Recommendation is live apply: the data set is small (about 720 libraries) and the redraw is cheap.
- **Faceted choices, never silent resets.** (Refined while writing `filter_logic.R`, 2026-10-22: the first version of this rule let a picked library narrow the city list to one city, which made it impossible to change city and see the notice below.) The rules, all implemented as pure functions and tested:
  - **Changed 2026-10-23 at the user's request:** the **city list is always complete**; a service no longer narrows it (the user expected the old behavior, and many cities have no service data, so Tampere vanished whenever a service was picked). The **service list depends on the city only**. Both show the number of libraries (`Espoo (14)`); a city's count is all of its libraries. A picked library narrows neither list. Picking a city the selected service isn't offered in **clears the service with a notice**. (Earlier version of this rule: the city list followed the service.)
  - The **library list depends on the city and the service**.
  - Picking a service never leaves the city invalid (the service list only has services the city has). Picking a city can: the selected service may not be offered there, and a picked library may not be in it. Both are cleared **with a short notice** ("Service cleared: it is not offered in Tampere", "Library cleared: it is not in Espoo", "Library cleared: it does not offer Sauna"), joined if both happen.
  - Picking a library sets the city to the library's city (the only time one dropdown writes to another). It does not touch the service: the library list only offers libraries that already match it.
  - Dropped on purpose: today a picked library narrows the service list to that library's own services. The detail panel already lists them, and the symmetric rule is easier to explain. Easy to add back if the user misses it.
- **The × buttons do the same thing as clearing by hand** (set the filter to empty through the same path), so there is no special case.
- **Find Nearest** respects the service filter (nearest *Sauna* library that is open) and says so; it does not touch the dropdowns, and "Reset filters" (or a × on a chip) returns to the filtered map.
- **Shareable URL.** The filters live in the query string (`?city=Espoo&service=Sauna&library=123`) via `updateQueryString()`; on load the app reads it. This replaces the reconnect seeding hack: a reconnected session starts from the same URL, and a library link can be sent to someone.

### 1.3 How to build it so it stays fixed

**One source of truth, one reducer, pure functions.**

```r
# app/www/filters.R  (new, no Shiny inside, fully unit-testable)
filter_options(libs, services, sel)      # -> list(cities=, services=, libraries=) named choice vectors with counts
apply_filter_change(libs, services, sel, changed = "city", value = "Espoo")
                                         # -> list(sel = new selection, notice = NULL or "Library cleared: ...")
filter_libraries(libs, services, sel)    # -> the libraries to draw
```

- In `server.R` one `reactiveValues` `sel` (city, service, library). One `observeEvent` per input calls `apply_filter_change()` **only if the value differs from `sel`** (that makes the browser's echo of our own `update*` calls a no-op, which is what removes the race), then one observer pushes `filter_options()` to the three dropdowns, sending a dropdown's choices only when they changed.
- The map observer reads `filter_libraries(libs, services, sel)`. `committed_*`, `pending_*`, the self-heal branch, the reconnect seeding observer and `update_service_choices_for_libraries()` are all deleted.
- Put the map drawing in a base `renderLeaflet` (tiles, legend) plus a `leafletProxy` that redraws markers and fits bounds (Fillari's pattern). Today a new `renderLeaflet` is created on every filter change, which resets zoom and flashes the tiles.
- Replace the `""`-valued "All" choices with real empty selection (`selectizeInput(..., options = list(placeholder = "All cities", allowEmptyOption = TRUE))`) so the placeholder and the "no filter" state are the same thing.

**Tests that would have caught the old bugs**
1. Pure tests for `filter_options()` and `apply_filter_change()`: a table of (state, change) → (state, notice), including the cases from the bug list in 1.1 (service pick keeps a valid library; city change clears an impossible library with a notice; library pick sets city; clear library widens service list; service offered in no library of the city is not in the list).
2. A property-style test: for random states, every value that `filter_options()` offers produces a non-empty result when selected, and the current selection is always among the offered values.
3. `testServer()` tests that `sel` and the drawn library ids follow the inputs, and that **setting `sel` to the value it already has changes nothing** (the echo test).
4. One `shinytest2` test (real browser) for what `testServer()` cannot see: pick a service, pick a city, see the dropdown labels and the map count agree; reload with the URL and see the same state. `shinytest2` needs `chromote`; add it to `renv.lock` inside the target image (see 4.3), and run it in `tests.yml` only if it is stable on the runner, otherwise as a manual check.
5. Real-browser check by hand before the deploy (the sibling plans all did this): each path in 1.2, mobile width, dark mode, a reconnect (`Shiny.shinyapp.$socket.close()`).

**Order inside Phase 1** (small commits, each reviewed with the running app on :8082 (on this machine: `docker run --network host -e PORT=8082`)): (a) pure functions + tests, no behaviour change (**done**, `app/www/filter_logic.R` and `tests/testthat/test-filter-logic.R`: `filter_libraries`, `filter_options`, `as_choices`, `apply_filter_change`; the tests include a random walk of 120 changes asserting that every offered choice gives a non-empty map and every selection stays among the offered choices, and three deliberate breakages of the logic were each caught); (b) switch the dropdowns to the reducer and delete the workarounds (**done 2026-10-23, kept "Show on Map"**: `selection()` replaces `pending_*`, `apply_filter_change()` + `push_dropdowns()` replace the five cascade observers and `update_service_choices_for_libraries()`; the x buttons still commit immediately; counts are shown in the city and service lists; tests rewritten for the new rules, plus tests that record what is sent to the browser and an echo test); (c) live apply, counts and notices (**done 2026-10-23**: no "Show on Map" and no `committed_*`; `libraries_on_map()` derives the map from `selection()`; the detail panel follows the library selection; summary line and "Reset filters" under the dropdowns; counts and notices came with (b)); reconnect re-checked in a real browser on 2026-10-23 (with server-side debug logging): found and fixed a bug where the re-sent startup event moved the city to Helsinki after the seeding (the map then disagreed with the dropdowns); after the fix a user change after the reconnect reaches the server and the map and summary follow; (d) `leafletProxy` split (**done 2026-10-23**: `output$map` renders once; `refresh_map()` in `functions.R` serves both the render and the proxy updates; the view only moves when the set of libraries changes, so a theme change keeps the zoom; tests: `test-map-drawing.R` and server tests that the base map is not rebuilt); (e) filters in the URL (**built 2026-10-23, branch `feat/url-filters`; the in-browser check of links was not possible when it was written (the Chrome extension was unreachable)**: `selection_to_query()`/`selection_from_query()` in `filter_logic.R`, `server/url.R`; a link restores a selection through the same rules, values that don't fit are left out with a notice, the address follows the selection and is not written before the link has been read; the reconnect seeding observer is kept as a fallback); (f) Find Nearest respects the service filter (**built 2026-10-23, branch `feat/nearest-service`**: `nearest_open_libraries()` in `functions.R`; the heading and the "none found" notice name the service; the city and library filters don't apply, i.e. the nearest libraries can be in the next city (an assumption at first; the user confirmed it on 2026-10-23 after seeing that a service only some Helsinki libraries offer continues into Espoo); the result is cleared when the city or service changes).

---

## 2. Phase 2 — structure (DONE 2026-10-22, PR #7, `8396ad8`, deployed)

Mechanical, no behaviour change. Result:

- `app/global.R` loads the packages, then `www/variables.R`, `strings.R`, `functions.R` and the stats module; `server.R` and `ui.R` load nothing themselves. `tests/testthat.R` sources `global.R` and `server.R`.
- `www/variables.R` holds the 14 map constants, the footer app list (**FillariStatus added**) and `geo_config` (geolocation timings).
- `www/strings.R` holds the text of `ui.R` and `server.R` as `txt$...`. **Not moved yet:** the text in `build_library_popup()` (`functions.R`) and in `modules/service_stats.R`.
- `www/app.js` replaces the inline script: timings come from `window.BIBLIO_CONFIG`, `asset()` cache-busts the file, the dead `checkMobile` handler is gone (nothing in the server sent it). Plan 11 (head-script race) stays handled by the `onShinyReady` polling already there.
- `server.R` is about 70 lines (state, reconnect seeding). The rest is in `app/server/{data,filters,map,panels}.R`, **parsed once when `server.R` loads (`server_parts`) and evaluated inside every session's `server()`**, in the original observer order. A first version used `source("server/...", local = TRUE)` at session time and failed in the tests, because testthat changes the working directory; do not go back to relative paths at session time.
- Not done from the original list: the `refresh` observer (`ignoreNULL = FALSE`, no `refresh` input) is still there, and `app/secret.R` was only confirmed git-ignored and excluded by `.dockerignore`.

Checked: a line-by-line comparison of the old and new server code (only the 19 `txt$` substitutions differ), 123 tests in the production image and in CI, the served page (app.js, config, footer) locally and on the live site, and the deploy (label `8396ad89cdee`, HTTP 200). The user clicked through the running app locally.

Environment lessons: on the user's machine the Docker bridge (`docker0`) drops traffic, so published ports (`-p`) and `docker compose up` do not work; `docker run --network host -e PORT=8082 ...` does. The browser pane also refused `localhost`. A CI run once hung 30 minutes on an apt mirror stall (now retried and capped at 10 minutes).

---

## 3. Phase 3 — data layer and correctness

1. **Never-throwing data layer with states** (Fillari `fetch_stations_safe`): `get_app_data()` returns `list(libraries, schedules, services, source = "turso"|"sqlite", fetched_at, stale, error)`. The UI shows a quiet note when it is on the SQLite fallback ("Showing the nightly backup; live data is unavailable") and a plain message when even that fails. Today the fallback is silent, and an empty `schedules` result makes every marker the "Unknown" purple.
2. **Shared cache across sessions** (`memoise` with a 5–10 minute TTL, as Fillari and Gallery do). Libraries and services change weekly, schedules daily; three Turso round trips per page load is waste and, on a Turso outage, three timeouts per visitor. Warm the cache at start. Add a request timeout and one retry for reads.
3. **Opening status goes stale during a session (fixed 2026-10-23, branch `feat/live-status`).** (Original note:) `refresh_data()` runs once per session and bakes `is_open_now` and `open_status` in. Sessions can now last an hour (timeout 3600 plus `"force"` reconnect). A library that opens at 10:00 still shows "Closed" at 10:45 until the page is reloaded. Fix: keep the day's schedule rows in the cache, and recompute `open_status` from the current Helsinki time in a `reactive` driven by `invalidateLater(60 * 1000)` (no database call); the markers and the detail panel redraw through the `leafletProxy`.
4. **Time zone (confirmed and fixed 2026-10-23, see item 8).** `fetch_schedules()` uses `format(Sys.Date(), ...)` and the container runs in UTC, while the status uses `Europe/Helsinki`. Between 00:00 and 02:00/03:00 Helsinki time the app asks for **yesterday's** schedules. Use `lubridate::today("Europe/Helsinki")` (or `format(Sys.time(), tz = "Europe/Helsinki", "%Y-%m-%d")`) in one `helsinki_now()` helper that both places and the tests use. Related (verify): `from <= now & to >= now` compares `"HH:MM"` strings, so a period that ends after midnight (`"22:00"`–`"02:00"`) never matches; check what Kirkanta sends for late-night opening.
5. **Staleness alert for the nightly job.** The data job commits every night, so GitHub's 60-day rule does not bite, but a failing job only sends GitHub's default email. Add a `/health` route in the `httpHandler` wrapper (Gallery's pattern): 200 `ok`, or 503 with `unavailable`, `empty` (no libraries), `no_schedules` (no rows for today) or `degraded` (served from the SQLite fallback). Add a Cloud Monitoring uptime check on it (every 5 minutes) with an email alert, definition kept in `monitoring/health-alert-policy.json`. The pipeline already fails loudly on a Turso write error (Plan 10c); keep that.
6. **Small things from the old plan that are still open:** Plan 11 (head-script race: see Phase 2), the `fetch_library_data.R` override CSVs are fine; `R/migrate_services.R` and `R/backfill_historical_data.R` still write row by row (only matters if they are run again).
7. **Security details to re-check:** popups already escape names/addresses (`htmlEscape`), but `library_url` goes into an `href`: allow only `http(s)://` URLs, as Tuneteller's plan does for Spotify links; the detail panel builds `mailto:` and `tel:` links from API text, so escape or validate them too. Check whether the CSP in `security.R` is still report-only (it has both `csp_enforced` and `csp_report_only` headers) and, if a full policy can be enforced, do it the way TuneTeller did (violation recorder in a throwaway copy, real use, then promote).
11. **Live statuses (done 2026-10-23, branch `feat/live-status`; fixes item 3).** `refresh_data()` used to compute every library's status once, with the clock at page load. Now it loads the schedule rows of today and tomorrow once and `refresh_statuses()` recomputes the statuses every minute (a little after the full minute) from the rows and the Finnish clock, replacing `library_data()` only when something changed (so the map isn't redrawn for nothing), refreshing the open details panel, and switching to the new day after midnight. `compute_library_statuses()`/`todays_schedules()` are pure and tested (boundary minutes, touching periods, closed days, day change). A new test found a bug in the earlier detail-panel code: it also reacted to `library_data()`, which would have closed the details of a library opened by a marker click at almost every minute; it now reacts to `selection()$library` only.
8. **No statuses in the morning (found by the user 2026-10-23, fixed on branch `feat/week-of-schedules`).** Every library was purple ("unknown") from midnight UTC until the nightly job ran. Cause: the pipeline stored only today's schedules, the app asks for today's date, and GitHub starts the 02:00 UTC job hours late (06:47 to 07:09 UTC the last six days, so no data until about 10:00 Finnish time). Fix: the pipeline fetches and stores 7 days from today (one request per library with `period.start`/`period.end`), replaces that window in Turso (so changed hours are picked up and repeated runs don't pile up rows; the old `INSERT OR IGNORE` could not catch rows with NULL times), writes the whole window to the SQLite backup (which also makes the fallback useful for a week), and refuses to overwrite data when more than half of the fetched rows are Unknown. `R/schedules.R` holds the dates and the parser, tested on saved API responses. The app uses the Finnish date (`helsinki_today()`; it used the server UTC date while judging open/closed in Finnish time), shows a notice above the map when there is no schedule data for today, and the legend explains the purple "No status data". **First run:** the first fetch after the merge writes a week to production Turso (about 9,000 rows instead of 1,500).
9. **The data workflow's apt step can stall (found 2026-10-23).** `fetch_data.yml` installed the GDAL stack like the tests workflow did; a manual run was stuck on it for 20+ minutes (no step timeout, default 6 hours). The script uses no spatial package (`terra`/`raster` are in `renv.lock` but unused), so GDAL is dropped there and in `tests.yml` (PR #13), apt retries, and the step is capped at 10 minutes. Possible later cleanup: remove the unused `terra`/`raster` from `renv.lock` (regenerate it in the image) to shrink the Docker build too.
10. **Page and map in opposite modes (found by the user 2026-10-23, fixed on branch `feat/theme-light-default`).** `bs_theme(bg = "#191414", fg = "#FFFFFF")` is the LIGHT mode in bslib, so the page was dark in "light" mode and light (inverted) in "dark" mode while the map followed the toggle's name. Measured in a real browser before the fix: "light" = page `#191414` + Light Gray map; "dark" = page `#E8E8E8` + Dark Gray map. Fix, like FillariStatus: an ordinary light theme with dark mode added on top (`app_theme()`), light by default (the user's choice), brand colours in `brand_colours`, theme-aware accent in the CSS (`--brand-accent`), and removal of dark-page-only colours (fixed dark sidebar, white loading text, leftover Spotify-green links, `#333` footer border). Checked in a real browser in both modes, including the statistics tab.

---

## 4. Phase 4 — CI/CD and infrastructure (DONE 2026-10-22)

What was done, with the commits and runs that prove it:

1. **`tests.yml`** (`4ab7774`): runs `tests/testthat.R` on push (code and test paths, not the nightly database commit), pull request, manual and as a reusable workflow; R version and packages from `renv.lock`. `tests/testthat.R` now exits non-zero on a failing test (it did not before, so CI would have stayed green). First run: `FAIL 0 | WARN 39 | PASS 123`. The 39 warnings are the expected Turso-to-SQLite fallback warnings (no credentials in CI); they would hide a real warning, so Phase 1 should make the tests quiet. *Not yet shown:* a failing test turning the run red.
2. **Deploy gate and smoke test** (`75cabac`): `deploy` needs `test`; `concurrency` group; `--update-labels git-sha=<12 chars>`; smoke test fails unless the label matches and `GET /` returns 200. Proved by manual deploys (run `39685540568` and later). `/health` is not part of it yet (Phase 3.5).
3. **Deploy timing** (`67cc10b`): decided with the user: deploy on code and build-file pushes (`app/**` except `app/libraries.sqlite`, `R/**`, `Dockerfile`, `.dockerignore`, `renv.lock`, `.Rprofile`, `renv/activate.R`, `renv/settings.json`), weekly (Monday 04:00 UTC) and manually; no longer after every nightly fetch. Trade-off recorded in `CLAUDE.md`: the SQLite fallback holds a single day of schedules, so an old image shows no opening hours in a Turso outage (Phase 3.1 should say so on screen). **The build is about 7-9 minutes, not 30-35**: the `Dockerfile` already uses Posit binaries. *Not yet exercised:* the push trigger and the first Monday run (2026-10-26).
4. **Pinned actions** (`e3ec3a8`): every `uses:` is a commit SHA; `id-token: write` only on the deploy job. Dependabot PRs: #6 `auth` v3.0.0 and #2 `setup-gcloud` v3.0.1 (each proved by a deploy: the log shows the new SHA, label matched, HTTP 200), #3 `cache` 6.1.0 (proved by a manual `fetch_data` run: cache restored, 1,488 schedule records written), #4 `checkout` 7.0.1 and #5 `send-mail` 3.12.0 merged. #1 (Docker `rocker/r-ver` 4.6.0) closed on purpose: the image's R must match `renv.lock` (4.5.2). *Not yet exercised:* the `send-mail` bump (next 03:00 UTC URL check).
5. **`renv.lock`**: checked, not regenerated: 98 packages on R 4.5.2, every declared requirement present, all from a repository source. CI and Docker restore from it. Regenerate it inside `rocker/r-ver:4.5.2` only when a package is added (local R is 4.6.1 and cannot restore it).
6. **Housekeeping**: service settings confirmed (concurrency 80, timeout 3600, session affinity, max 3 instances, `bibliostatus-runtime`). **The Artifact Registry had no cleanup policy**: 344 images, 138.8 GB. `infra/artifact-registry-cleanup.json` (keep the 5 newest versions, delete versions older than 14 days) was applied by the user on 2026-10-22 (dry run first, then real); read back as active. Google applies it about once a day: check the repository size has dropped (e.g. on 2026-10-24) and that the live revision is intact. **The budget alert could not be read** (the Billing Budgets API is not enabled for the project gcloud used; it was not enabled): check in Cloud console under Billing, Budgets & alerts. Uptime check: none yet (Phase 3.5).
7. **Leftovers**: none. The GitHub secrets are `GCP_PROJECT_ID`, `TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN`, `EMAIL_USERNAME` and `EMAIL_PASSWORD`, all used; `SHINY_APPS_*`, `GCP_SA_KEY` and `CARTO_API_KEY` no longer exist.

Lessons from this phase: production merges and workflow dispatches were blocked by the auto-mode classifier here, so the user ran them and pasted the output back; `git pull --rebase` needs `--autostash` while the `full-fix-plan.md` deletion is pending; `gh run watch` for a deploy takes longer than the 10-minute foreground limit, run it in the background.

---

## 5. Order of work, verification and housekeeping

### 5.1 Order
0. `git pull --rebase` (3 data commits behind), commit or move the plan files.
1. ~~Phase 4~~ done (tests in CI, deploy gate, pins, cleanup policy).
2. Phase 2 (structure), reviewed by running the app.
3. Phase 1 in the order given in 1.3, user review after (b) and (c) because they change what the user sees (**done**; now (d), (e), (f)).
4. Phase 3: item 4 (time zone) and item 8 (the week of schedules) are **done**; next the stale status within a session (item 3), then `/health` (item 5) and the data layer (items 1 and 2).
5. One deploy per phase, with the verification below. Work on a branch and open a pull request: `tests.yml` runs on pull requests, and merging to `main` triggers the single deploy (pushes to `main` that touch `app/**` deploy automatically).

### 5.2 Verification (as the user's rules require)
- After each commit/push: `git status`, `git ls-remote origin refs/heads/main` equals `HEAD`, and read the workflow run result from GitHub; never suppress errors in scripts that call GitHub or cloud APIs.
- After each deploy: revision and `git-sha` label, HTTP 200, `/health`, logs, and use the live app (each dropdown path, a reconnect, dark mode, mobile width). If a fix fails, find the root cause and try something different rather than repeating it.
- `R CMD check` does not apply (this is an app, not a package), but run the whole suite locally and in CI before every push.

### 5.3 Known gaps to keep honest
- The earlier browser checks used headless Chromium and the Chrome tools; the user has said they were unreliable and that their own browser result wins. For the dropdown work, **ask the user to run through the paths in 1.2 on the local build** before it is deployed.
- Phones, Safari and Firefox have not been checked in any sibling plan; the map's mobile branch (`is_mobile`, touch options) is unverified on a real phone.
- `testServer()` cannot simulate `update*Input()` round trips; Phase 1 reduces what depends on them, and one `shinytest2` test covers the rest.

### 5.4 Docs to update when done
`CLAUDE.md` (the filter section is very long and mostly describes workarounds that will be gone: replace with the new model), `README.md`, `DEPLOY.md`, the project page, and the `docs/` text if it describes "Show on Map". Move this file and the other plans under `docs/plans/` or keep them untracked; decide with the user.

## 6. Decisions to confirm with the user

| Question | Proposed |
|---|---|
| Live apply vs keeping "Show on Map" | Live apply, with a result count and Reset (1.2) |
| City list narrowed by the other filters, with counts | Yes |
| Selection invalidated by another change | Clear it and show a short notice |
| Find Nearest respects the service filter | Yes |
| Filters in the URL | Yes |
| Deploy on every nightly fetch | No: on code changes plus a weekly refresh (4.3) |
| Add FillariStatus to the footer | Yes |
| Finnish/Swedish UI | Later; Phase 2 only prepares `strings.R` |
