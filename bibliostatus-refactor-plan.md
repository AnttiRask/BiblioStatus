# BiblioStatus — Refactor Plan

> Bring BiblioStatus in line with how FillariStatus, Gallery of the Day and TuneTeller now work (`fillaristatus-plan.md`, `gallery-of-the-day-refactor-plan.md`, `tuneteller-refactor-plan.md`), and **fix the filter dropdowns properly instead of patching them again**.
>
> **For Claude Code:** read this whole file first. Phase 1 is the dropdown redesign and is the part the user cares most about. Every change is checked with the user before it is committed, pushed or deployed. Phase 4 touches cloud resources and GitHub settings: each step needs approval. Pushes that change the build files redeploy the app, so batch them. Never print secrets.

*Written 2026-10-22. Based on reading the three sibling plans and the current `app/server.R`, `app/ui.R`, `app/www/functions.R`, `app/run.R`, `Dockerfile`, the three workflows and `tests/testthat/`. Nothing here has been run or changed yet. Items marked (verify) are suspicions from reading the code, not confirmed behaviour.*

---

## 0. Where things stand

**Repo state (checked 2026-10-22):** local `main` is at `28b5ea7`, `origin/main` at `2058e7a`. Local is **3 commits behind, 0 ahead**. The three missing commits are the nightly "Update database" commits (2026-10-19, -20, -21), which only change `app/libraries.sqlite`. Pull before editing (`git pull --rebase`); the bot commits every night. The working tree also has `full-fix-plan.md` deleted (it was moved to `fixes/full-fix-plan.md`, untracked) and the four plan files untracked; decide whether to commit them (see 5.4).

**What the siblings did that BiblioStatus has not:**

| Practice | FillariStatus | Gallery | TuneTeller | BiblioStatus now |
|---|---|---|---|---|
| `global.R`, `variables.R`, `strings.R` split | yes | yes | yes | no: libraries and 14 constants at the top of `server.R`, UI text inline, a 140-line inline JS block in `ui.R` |
| JS in its own file | yes | yes (`lightbox.js`) | n/a | no |
| Never-throwing data layer with explicit states (ok / stale / error / empty) | yes | yes | yes | partly: Turso→SQLite fallback, but an empty or failed read just gives a blank or all-grey map |
| Shared server-side cache across sessions | yes (60 s) | yes (5 min) | n/a | no: every session runs three Turso queries on load |
| `/health` + uptime alert | no | yes | no | no |
| Tests in CI, gating the deploy | yes (in workflow) | `tests.yml` | `tests.yml` | **no**: 562 lines of tests exist but no workflow runs them |
| Deploy smoke test (checks `git-sha` label) | yes | yes | yes | no |
| Actions pinned to SHAs, minimal `permissions` | yes | yes | yes | no (`@v4`, `cache@v3`; `fetch_data.yml` has `contents: write` for the whole job) |
| Keyless deploy, dedicated runtime account, no `roles/editor` | yes | yes | yes | yes (done 2026-10-18) |
| Security headers | yes | yes | yes | yes (`app/www/security.R`) |
| Reconnect (`allowReconnect("force")`) | yes | considered | no | yes, plus the seeding hack |
| Artifact Registry cleanup + budget alert | yes | yes | yes | (verify) |

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
3. **Silent resets.** A selection disappears with no message when another dropdown changes. The user sees "I picked X and it went back to All".
4. **Server-written inputs read back.** `updateSelectInput()` / `updateSelectizeInput()` write to the browser and the browser echoes the value back to `input$*` later, which re-fires the other observers. The code works around this with `pending_service`, `pending_library`, `isolate(input$...)` reads, a "self-heal" branch in the map observer, a once-only seeding observer for reconnects, and `ignoreInit` flags. That is five workarounds for one design problem, and `testServer()` cannot test the round trip (noted in `test-server-filters.R`), so the part that breaks is exactly the part that is untested.
5. **Library choices are re-sent on every change** (`server = TRUE`, ~700 choices) and the label for "no selection" is an empty-string choice ("All Libraries") that selectize also uses as placeholder.
6. **Find Nearest ignores the filters** and replaces the map markers through a second code path (`update_map_for_nearest`) that the filter observer then overwrites on its next run; the city observer clears the nearest results as a side effect.

### 1.2 Target behaviour (proposed; confirm with the user before building)

One mental model: **three filters that narrow the map, live.**

- **Live apply.** The map follows the dropdowns as they change (debounced about 300 ms). "Show on Map" goes away. A line under the filters says what is showing: "12 libraries · Espoo · Sauna", and a **Reset filters** link returns to the post-startup state (startup city, nothing else).
  *Alternative if the user wants to keep the button:* keep it, but then **every** path, including ×, startup and reset, waits for it, and the button turns into "Apply (3 changes)" so the pending state is visible. Recommendation is live apply: the data set is small (about 720 libraries) and the redraw is cheap.
- **Faceted choices, never silent resets.** Each dropdown lists only values that still give at least one library under the *other two* filters, with a count:
  - City: `Espoo (14)`, only cities with a library matching the service (and library, if picked).
  - Service: only services offered by libraries in the chosen city (and by the chosen library, if picked).
  - Library: only libraries in the chosen city that offer the chosen service.
  Because the lists are derived from the other filters, a current selection is always valid. The one exception is a change that makes another selection impossible (new city, picked library is elsewhere). Then the dependent selection is cleared **and a short notice says so** ("Library cleared: it is not in Espoo").
- **Library implies city, one way only.** Picking a library sets the city to the library's city (the user expects the map to go there) and that is the only write between dropdowns. It happens through the one reducer below, so it cannot echo.
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

**Order inside Phase 1** (small commits, each reviewed with the running app on :8082): (a) pure functions + tests, no behaviour change; (b) switch the dropdowns to the reducer and delete the workarounds; (c) live apply, counts and notices; (d) `leafletProxy` split; (e) URL state; (f) Find Nearest respects the service filter.

---

## 2. Phase 2 — structure (mechanical, behaviour unchanged)

Do this **before** Phase 1(b) if the diff is easier that way; it is purely moving code.

- `app/global.R`: libraries and `source()` calls (today `server.R` and `ui.R` each load their own, and `server.R` has a commented "local version" switch).
- `app/www/variables.R`: move the 14 constants out of `server.R` (marker radii, popup widths, zoom, nearest counts) and the geolocation timings out of the JS.
- `app/www/strings.R`: all user-facing text (titles, labels, placeholders, notifications, the footer disclaimer). English only for now, structured so Finnish and Swedish can be added (the TODO in memory).
- `app/www/app.js`: the inline script in `ui.R` becomes a file. That is also where Plan 11 (head-script race) ended up: it already polls for `Shiny.setInputValue`; a file loaded after Shiny removes the polling.
- Footer list in `variables.R` (as the siblings do); **add FillariStatus** (the three siblings all link it, BiblioStatus does not).
- Split `server.R` (868 lines) into focused files: `data.R` (fetch + cache + statuses), `filters.R` (Phase 1), `map.R` (base map, markers, nearest), `panels.R` (the library detail panel and nearest list). `service_stats` stays a module.
- Cache-busting `asset()` helper for CSS/JS (Fillari §12: browsers cache `styles.css`).
- Delete or rename dead code found on the way: the `refresh` observer with `ignoreNULL = FALSE` and no `refresh` input in the UI (it is an "on load" trigger written as a button handler), the `checkMobile` message handler if nothing sends it (Plan 11 asked to check this), `app/secret.R` (listed in the tree; verify it is git-ignored and not in the image: the `.dockerignore` already excludes `**/secret.R`).

---

## 3. Phase 3 — data layer and correctness

1. **Never-throwing data layer with states** (Fillari `fetch_stations_safe`): `get_app_data()` returns `list(libraries, schedules, services, source = "turso"|"sqlite", fetched_at, stale, error)`. The UI shows a quiet note when it is on the SQLite fallback ("Showing the nightly backup; live data is unavailable") and a plain message when even that fails. Today the fallback is silent, and an empty `schedules` result makes every marker the "Unknown" purple.
2. **Shared cache across sessions** (`memoise` with a 5–10 minute TTL, as Fillari and Gallery do). Libraries and services change weekly, schedules daily; three Turso round trips per page load is waste and, on a Turso outage, three timeouts per visitor. Warm the cache at start. Add a request timeout and one retry for reads.
3. **Opening status goes stale during a session (verify).** `refresh_data()` runs once per session and bakes `is_open_now` and `open_status` in. Sessions can now last an hour (timeout 3600 plus `"force"` reconnect). A library that opens at 10:00 still shows "Closed" at 10:45 until the page is reloaded. Fix: keep the day's schedule rows in the cache, and recompute `open_status` from the current Helsinki time in a `reactive` driven by `invalidateLater(60 * 1000)` (no database call); the markers and the detail panel redraw through the `leafletProxy`.
4. **Time zone (verify, probably a real bug).** `fetch_schedules()` uses `format(Sys.Date(), ...)` and the container runs in UTC, while the status uses `Europe/Helsinki`. Between 00:00 and 02:00/03:00 Helsinki time the app asks for **yesterday's** schedules. Use `lubridate::today("Europe/Helsinki")` (or `format(Sys.time(), tz = "Europe/Helsinki", "%Y-%m-%d")`) in one `helsinki_now()` helper that both places and the tests use. Related (verify): `from <= now & to >= now` compares `"HH:MM"` strings, so a period that ends after midnight (`"22:00"`–`"02:00"`) never matches; check what Kirkanta sends for late-night opening.
5. **Staleness alert for the nightly job.** The data job commits every night, so GitHub's 60-day rule does not bite, but a failing job only sends GitHub's default email. Add a `/health` route in the `httpHandler` wrapper (Gallery's pattern): 200 `ok`, or 503 with `unavailable`, `empty` (no libraries), `no_schedules` (no rows for today) or `degraded` (served from the SQLite fallback). Add a Cloud Monitoring uptime check on it (every 5 minutes) with an email alert, definition kept in `monitoring/health-alert-policy.json`. The pipeline already fails loudly on a Turso write error (Plan 10c); keep that.
6. **Small things from the old plan that are still open:** Plan 11 (head-script race: see Phase 2), the `fetch_library_data.R` override CSVs are fine; `R/migrate_services.R` and `R/backfill_historical_data.R` still write row by row (only matters if they are run again).
7. **Security details to re-check:** popups already escape names/addresses (`htmlEscape`), but `library_url` goes into an `href`: allow only `http(s)://` URLs, as Tuneteller's plan does for Spotify links; the detail panel builds `mailto:` and `tel:` links from API text, so escape or validate them too. Check whether the CSP in `security.R` is still report-only (it has both `csp_enforced` and `csp_report_only` headers) and, if a full policy can be enforced, do it the way TuneTeller did (violation recorder in a throwaway copy, real use, then promote).

---

## 4. Phase 4 — CI/CD and infrastructure (each step needs approval)

1. **`tests.yml`**: run `tests/testthat.R` on push and pull request, on the packages in `renv.lock` (R version from the lockfile, `setup-renv`; Gallery and TuneTeller have working versions to copy). Today nothing runs the 562 lines of tests, so a push that breaks them still deploys.
2. **Gate the deploy on the tests and add a smoke test.** `deploy_shiny_app.yml`: `needs: tests`, add `--update-labels git-sha=${{ github.sha }}`, and a final step that fails unless the service's `git-sha` label equals the commit, `GET /` is 200 and `GET /health` is `ok`. Add `concurrency:` (the workflow has none, and the siblings' notes warn about starting two builds at once).
3. **Decouple the data refresh from the deploy (decision needed).** Today the deploy runs after *every* nightly fetch, i.e. a full image build every day, because the SQLite fallback is baked into the image. Options: (a) keep, for a fresh fallback; (b) deploy only on `app/**` and build-file changes, as Fillari does, and let the fallback age (Turso is the primary source, and Phase 3.1 shows when the fallback is used); (c) weekly. Recommendation: (b) plus (c)'s Sunday refresh via the existing "both" run. The memory note says Cloud Build has no layer cache and builds took 30–35 minutes; the current `Dockerfile` already restores from Posit's Linux binaries, so **re-measure a build before assuming it is still slow**.
4. **Pin actions to commit SHAs** in all three workflows, give each job the minimum `permissions` (the data job needs `contents: write` only for its commit step), upgrade `actions/cache@v3`, keep `dependabot.yml`. Merge Dependabot bumps one at a time and prove each by a deploy (TuneTeller §6).
5. **Complete, current `renv.lock`:** regenerate it inside `rocker/r-ver:4.5.2` (the image), check every `Requirements` entry is present, and add `shinytest2`/`chromote` only if used. Keep the compact-format requirement in mind for the data workflow (Gallery's note), and restore it in CI before merging.
6. **Housekeeping checks (read-only first):** Artifact Registry cleanup policy (keep the 5 newest), a budget alert for this project (the shared EUR 30/month one covers the billing account), `--max-instances 3` (set), concurrency 80 (**do not lower it**: lowering it to 20 once caused 404s for Shiny assets), `--timeout 3600 --session-affinity` (set), uptime check from 3.5.
7. **Leftovers:** the old `SHINY_APPS_*` GitHub secrets (memory TODO) and `GCP_SA_KEY` if it still exists. Ask before deleting each.

---

## 5. Order of work, verification and housekeeping

### 5.1 Order
0. `git pull --rebase` (3 data commits behind), commit or move the plan files.
1. Phase 4.1–4.2 first (tests in CI, deploy gate): cheap, and it protects everything after.
2. Phase 2 (structure), reviewed by running the app.
3. Phase 1 in the order given in 1.3, user review after (b) and (c) because they change what the user sees.
4. Phase 3, items 4 (time zone) and 3 (stale status) first: they are user-visible bugs.
5. One deploy per phase, with the verification below. Phase 4.3 onward after the app changes are live.

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
