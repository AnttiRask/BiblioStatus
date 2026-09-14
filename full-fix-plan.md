# BiblioStatus — 10 Sequential Improvement Plans

## Context

A code review of BiblioStatus surfaced 10 independent improvement areas. Each is turned into a fully detailed, independently executable plan below — meant to be implemented **one at a time**, in order, not all at once. Each plan is self-contained: it can be handed off and executed without re-reading the others. Do not start item N+1 until item N is verified working.

Two of the ten items (2 and 6) turned out, after deeper investigation, to be smaller/different than the original one-line summary suggested — noted inline.

---

## PLAN 1 — Fix the two known filter-cascade bugs

### Problem
Two bugs reported in `fixes.md:4-5`:
1. "Clear All Selections" doesn't reset the map to its post-startup state.
2. Selecting a service then switching city causes the service dropdown label to revert to "All Services" even though the filter is still active.

### Root cause (verified in `app/server.R`)
The map render observer (`app/server.R:264-311`) filters exclusively on `committed_city()`, `committed_service()`, `committed_library()` — reactiveVals that are written in exactly 4 places: the "Show on Map" button handler (`apply_filters`, lines 247-259) and the 3 startup/geolocation observers (lines 121-152, city only).

The clear-button handlers do **not** write to these committed values:
```r
# app/server.R:235-238
observeEvent(input$clear_library, {
  updateSelectizeInput(session, "library_search", selected = "")
  selected_library(NULL)
})

# app/server.R:240-243
observeEvent(input$clear_service, {
  updateSelectInput(session, "service_filter", selected = "")
  selected_library(NULL)
})
```
Clicking either clear button resets the *displayed* dropdown but leaves `committed_library`/`committed_service` untouched, so the map keeps showing the old filtered result until "Show on Map" is pressed again. There is no `clear_city` button in the current UI at all (checked `app/ui.R` — only `clear_library` and `clear_service` action buttons exist).

For bug 2, `city_filter`'s cascade observer (`app/server.R:172-202`) reads `current_service <- isolate(input$service_filter)` to compute library choices, but by design (comment at lines 168-171) never calls `updateSelectInput` on `service_filter` itself — so its displayed value is whatever it was before, and nothing re-affirms it, while nothing resets it either. The actual visible "reset to All Services" behavior needs to be traced against the specific reproduction steps (this may be a UI-library quirk with `selectInput`'s choices being reset elsewhere) — the fix approach below handles it regardless of exact trigger by making the label authoritative.

### Fix approach
1. **Make clear buttons write through to committed state**, mirroring the exact pattern already used by `apply_filters` (`server.R:247-259`):
   ```r
   observeEvent(input$clear_library, {
     updateSelectizeInput(session, "library_search", selected = "")
     selected_library(NULL)
     committed_library("")
   })

   observeEvent(input$clear_service, {
     updateSelectInput(session, "service_filter", selected = "")
     selected_library(NULL)
     committed_service("")
   })
   ```
   This is the minimal, targeted fix — it makes "clear" immediately affect the map without requiring "Show on Map", which matches the user's stated expectation ("return it to the same state where it was after we opened the app").

2. **Add a "Clear All" affordance if one doesn't already exist as a single button** — check `app/ui.R` for whether "Clear All Selections" is a single button wired to its own observer or just the user's name for clicking both clear buttons. If it's a dedicated button/observer, apply the same `committed_*("")` writes there (plus `committed_city("")` or reset to `startup_city()`, matching whatever "post-startup state" means — likely reset to the originally-detected/fallback city, not blank, per the user's wording "the same state where it was after we opened the app and chose to use the current city").

3. **Fix the service-label desync** by having the `city_filter` observer (`app/server.R:172-202`) re-affirm the service dropdown's selected value only when it's still valid for the new city, rather than leaving it un-touched. Add after the existing `updateSelectizeInput` call for `library_search` (after line 196):
   ```r
   # Re-affirm the currently selected service so its label doesn't drift,
   # but only if that service still has results in the new city.
   if (!is.null(current_service) && current_service != "") {
     service_still_valid <- current_service %in% (all_svcs %>%
       filter(library_id %in% (all_libs %>% filter(city_name == input$city_filter) %>% pull(id))) %>%
       pull(service_name))
     updateSelectInput(session, "service_filter",
       selected = if (service_still_valid) current_service else "")
   }
   ```
   This must NOT trigger a re-entrant call into the `service_filter` observeEvent in a way that reintroduces the race the original comment (lines 168-171) was avoiding — verify by testing the exact repro steps from `fixes.md:5` after the change (select service → switch city → confirm label stays correct AND library choices stay correct).

4. Keep the existing self-heal logic in the map render observer (`server.R:305-311`) as a safety net — it's independently useful and shouldn't be removed.

### Files to modify
- `app/server.R` — the two clear-button observers (235-243), the city_filter cascade observer (172-202), and whatever "Clear All" mechanism exists (locate via `app/ui.R` grep for the action button feeding it).

### Verification
- Manually reproduce both bugs as described in `fixes.md:4-5` before changing anything (confirm current broken behavior).
- After the fix: select a city, select a library, click "Clear Library" → map should immediately show all libraries in that city (no need to click "Show on Map").
- Select a service, switch city to one that still has that service → service dropdown should keep showing the selected service name.
- Select a service, switch city to one that does NOT have that service → service dropdown should reset to "All Services" and library choices should reflect no service filter.
- Run through the existing manual QA path (`docker compose up --build`, exercise map filters) since there is no automated test harness yet (see Plan 3).

---

## PLAN 2 — Sidebar toggle-arrow overlap

### Problem
`fixes.md:1-2`: the sidebar collapse-toggle arrow overlaps buttons/dropdowns; user wants a smaller left margin so content shifts left and the toggle has room.

### Root cause (verified in `app/www/styles.css` and `app/ui.R`)
A previous fix attempt already exists at `styles.css:292-323` (comments literally describe the intended fix), but two things are still fighting it:

1. **A stale/orphaned CSS block** at `styles.css:105-123`:
   ```css
   .sidebar {
     background-color: #1a1a1a;
     border-radius: 5px;
     padding: 15px;
   }
   .sidebar-panel h4,
   .sidebar-panel b { color: #C1272D; }
   .sidebar-panel p,
   .sidebar-panel span,
   .sidebar-panel div { color: #000000; }
   ```
   `.sidebar-panel` does not exist anywhere in current `ui.R` markup (bslib's `sidebar()` doesn't emit that class) — dead CSS. But the bare `.sidebar` selector **does** match bslib's real DOM (`.bslib-sidebar-layout > .sidebar`), so this rule's `padding: 15px` is live and stacks with the newer, more specific padding rule at `styles.css:310-318` (`padding-left: 8px; padding-right: 36px` on `.sidebar-content`, one level deeper). Two different elements in the same box each carrying their own padding is the likely source of the toggle still not having enough clearance.

2. **No `sidebar()` params set in `ui.R`** beyond `width = 400` (`app/ui.R:157-158`) — no `id`, no custom collapse behavior — so the toggle button itself is 100% bslib/Bootstrap default-positioned; this repo's CSS only ever nudges it with `margin-right: 8px` (`styles.css:297-299`), never touches its actual position/z-index.

### Fix approach
1. Remove the dead `.sidebar-panel` rules (`styles.css:112-123`) — confirmed unused, safe to delete.
2. Resolve the double-padding: keep the outer `.sidebar` background/border-radius styling (lines 106-110) but drop its `padding: 15px` (since the inner `.sidebar-content` already sets deliberate left/right padding for exactly this purpose per the comment at 306-309). Verify visually after removal that content isn't flush against the sidebar edge — if so, adjust `.sidebar-content`'s `padding-left`/`padding-right` values directly instead of restoring the outer padding.
3. Re-test the toggle button clearance at both the default sidebar width (400px) and at a mobile breakpoint (bslib collapses/changes behavior on mobile per default `open = "desktop"`) — the CSS currently has no `@media` query for this section at all, so confirm whether the overlap is mobile-specific, desktop-specific, or both before deciding if a breakpoint-specific rule is needed.
4. This needs actual in-browser verification (not just reading CSS) — start the app (`docker compose up --build` or `shiny::runApp("app/")`), open dev tools, inspect the actual computed box model around `.collapse-toggle` and `.sidebar-content` to confirm which declaration is the real culprit before finalizing values.

### Files to modify
- `app/www/styles.css` (lines 105-123 removal, 292-323 adjustment)

### Verification
- Load the app in a browser at desktop width; confirm the toggle arrow has clear space and doesn't sit on top of any dropdown or button.
- Resize to mobile width; confirm the same.
- Toggle the sidebar closed/open a few times to confirm no layout jump introduced by the padding change.

### Outcome (done)
Removed the dead `.sidebar-panel` rules and the outer `.sidebar { padding: 15px }` (kept `background-color`/`border-radius`) — confirmed via `grep` that `.sidebar-panel` matches nothing in any `.R` file.

**Verified in a real browser** (Playwright + headless Chromium, since no interactive browser tool was available) at desktop (1280px), laptop (1024px), tablet (768px), and mobile (390px, sidebar opened via the toggle) — before AND after the CSS change:
- No actual overlap between the `.collapse-toggle` button and any dropdown/button was reproducible at **any** tested width, in either the pre-fix or post-fix CSS.
- Box-model measurements were byte-identical before/after (toggle at x357–389, sidebar-content padding reserving space correctly up to x412) — meaning the removed `padding: 15px` wasn't actually causing a visible collision at these widths.

**Conclusion**: the CSS cleanup itself is legitimate (removes genuinely dead/conflicting rules, matches the plan's diagnosis) and was applied, but the specific overlap the user reported in `fixes.md:1-2` could not be reproduced at any standard viewport width tested. Git history shows a prior commit (`b2bd08b`, titled "Fix sidebar toggle overlap, clear map reset, service filter text, chart colors") already attempted this exact fix — it's possible that commit already resolved the visible issue and `fixes.md` predates verifying that, or the overlap is specific to a viewport size, browser zoom level, or a font-loading race (the Gotham web font swapping in late could transiently shift text width) not covered by this testing. **Needs the user to confirm in their own browser** whether the overlap still reproduces; if so, the exact window size/zoom/OS where it appears would narrow this down further.

---

## PLAN 3 — Add automated tests

### Problem
Zero test coverage across ~2,500 lines of R (no `tests/`, no `testthat.R`, nothing). This is the highest-leverage gap given Plan 1 fixes a bug class that a regression test would directly protect.

### Approach
Add `testthat` (3rd edition) infrastructure and start with the highest-value, lowest-effort tests — pure functions first, then a `testServer()` test for the filter cascade.

1. **Scaffold**: `usethis::use_testthat(3)` at the project root (or manually create `tests/testthat.R` + `tests/testthat/` if `usethis` isn't already a dependency — check `renv.lock` first, add if missing via `renv::install("testthat")` + `renv::snapshot()` per this repo's established pattern).

2. **Unit tests for pure helpers in `app/www/functions.R`**:
   - `calculate_distance` / `calculate_distances_to_libraries` (lines 87-116, Haversine distance) — test with known coordinate pairs and expected distances (e.g. two identical points → 0; two known cities with a known real-world distance, allowing small tolerance).
   - `format_schedule_periods` (lines 120-147) — snapshot test: given a fixed set of schedule rows and a fixed "now" timestamp, assert the exact HTML/text output. Since this depends on `Sys.time()`, the function (or a test wrapper) needs the "now" injectable — check its signature; if `now` isn't already a parameter, add one with a default of `Sys.time()` so tests can pass a fixed value without changing production call sites.

3. **`testServer()` test for the filter cascade** (regression-proofing Plan 1): simulate `input$city_filter`, `input$service_filter`, `input$library_search`, `input$clear_library`, `input$clear_service`, `input$apply_filters` in sequence and assert `committed_city()`/`committed_service()`/`committed_library()` reach the expected values at each step — this directly encodes the two bug scenarios from `fixes.md:4-5` as regression tests.

4. **Fixture-based test for `turso_query`'s JSON parsing** (`R/turso.R:106-137`): capture a realistic `/v2/pipeline` JSON response shape (can hand-construct based on the exact request/response structure documented in Plan 5 below) as a fixture, and assert the parsed data frame has correct column types (this test would have caught the divergence found in Plan 4, where `app/www/turso.R`'s copy skips `type.convert()`).

### Files to add
- `tests/testthat.R`
- `tests/testthat/test-functions.R` (distance + schedule formatting)
- `tests/testthat/test-server-filters.R` (testServer cascade test)
- `tests/testthat/test-turso.R` (fixture-based parsing test)
- `tests/testthat/fixtures/turso_pipeline_response.json`

### Verification
- `devtools::test()` or `testthat::test_dir("tests/testthat")` runs clean.
- Deliberately re-introduce the Plan 1 bug locally and confirm the new `testServer()` test fails, then re-apply the fix and confirm it passes — proves the test actually catches the regression class it's meant to.

### Outcome (done)
Added `tests/testthat.R` + 3 test files + 1 fixture, exactly per plan, plus one small enabling refactor: extracted `turso_query()`'s response-parsing logic (`R/turso.R:87-137`) into a standalone `parse_turso_query_result(result)` function, so it can be unit-tested against fixture JSON without making a live HTTP call. `format_schedule_periods` already took `now_time` as an explicit parameter, so no change was needed there.

**31/31 tests pass** (`FAIL 0 | WARN 6 | SKIP 0 | PASS 31`) — the 6 warnings are the expected, benign Turso→SQLite fallback warnings firing during the server's own startup data-refresh observer (this container's local Turso credentials don't resolve against the real cloud DB), not test failures.

One thing narrower than originally planned: the `testServer()` cascade tests cover the two `committed_*` write-through bugs (clear_library/clear_service) directly, but **not** the service-label-resync behavior from Plan 1 item 3. Discovered mid-implementation that `shiny::testServer()` does not simulate the client-side JS round-trip `updateSelectInput()`/`updateSelectizeInput()` depend on to feed a changed value back into `input$x` — confirmed via a minimal repro. Any assertion on `input$service_filter` after such a call would pass/fail based on this testServer limitation, not actual app behavior. That specific behavior remains verified only by the one-off Playwright browser script used during Plan 1 — a permanent regression test for it would need `shinytest2` (drives a real browser) rather than `testServer()`. Noted in `tests/testthat/test-server-filters.R` as a comment for future reference.

Also required adding `testthat` (and its transitive deps: `brio`, `callr`, `desc`, `diffobj`, `pkgbuild`, `pkgload`, `praise`, `processx`, `ps`, `waldo`) to `renv.lock`. Getting a clean lockfile diff required care: a bare `docker run` with the whole repo bind-mounted lost renv's library-path context and `renv::snapshot()` nearly wiped the lockfile down to 33 lines (caught before committing, reverted immediately via `git checkout`). The working approach: snapshot inside a normal `docker compose` container (isolated filesystem, correct renv context), then hand-merge just the new package JSON blocks into the host's `renv.lock` at their correct alphabetical positions via exact text extraction — not a full JSON reparse/rewrite, which would have reformatted the entire file. Final diff: 426 insertions, 0 deletions, exactly the 11 new packages.

---

## PLAN 4 — Consolidate the duplicated Turso client

### Problem
`R/turso.R` (202 lines, full read/write client) and `app/www/turso.R` (117 lines, read-only copy) have diverged, not just been copy-pasted:

- `app/www/turso.R`'s `turso_query()` skips the `type.convert()` coercion step that `R/turso.R`'s version does (`R/turso.R:135` vs. `app/www/turso.R:108-113`) — meaning Turso-sourced columns in the app stay character-typed while the SQLite-fallback path naturally types them via `dbReadTable`/`dbGetQuery`. This is a real, silent behavioral inconsistency between the two data paths the app can take.
- `app/www/turso.R` has no `load_turso_credentials()` helper; it inlines credential resolution and only checks `url == ""` before falling back to a global variable (not `token == ""`), an asymmetric condition that's a latent edge-case bug.
- `app/www/turso.R` has no `turso_execute()` at all (confirmed no call sites under `app/`, so this omission is currently harmless).

### Fix approach
Make `R/turso.R` the single source of truth; have the app source it instead of maintaining a second copy.

1. In `app/www/functions.R:1-9`, replace:
   ```r
   source("www/turso.R")
   ```
   with a `here()`-based path to the root client (the app already uses `here()` elsewhere, e.g. `functions.R:18`):
   ```r
   source(here::here("R/turso.R"))
   ```
   Verify `here` is loaded before this line (check top of `functions.R`/`server.R` for `library(here)`).

2. Delete `app/www/turso.R` entirely once nothing sources it (confirm via repo-wide grep for `www/turso.R` and `app/www/turso.R` after the change).

3. `R/turso.R`'s `load_turso_credentials()` already checks both `secret.R` (repo root) and `app/secret.R` (line 24 fallback) — so this consolidation doesn't break local dev in either working-directory context (root scripts run from repo root; Shiny app runs with `app/` as its working directory, but `load_turso_credentials()`'s relative `file.exists("secret.R")`/`file.exists("app/secret.R")` checks only work correctly if run from the repo root — **verify this specifically**, since when Shiny sets its CWD to `app/`, `file.exists("app/secret.R")` would resolve to `app/app/secret.R`, which doesn't exist. This may need `load_turso_credentials()` updated to use `here::here("secret.R")` and `here::here("app/secret.R")` instead of bare relative paths, to work correctly regardless of caller's CWD.

4. Since `turso_execute()` becomes reachable from the app process after this change (harmless — nothing currently calls it from `app/`), no action needed there, but worth a one-line note in `CLAUDE.md`'s "Turso API Usage" section that the app now has write capability available (even if unused) so a future contributor doesn't assume otherwise.

### Files to modify
- `app/www/functions.R` (source line)
- `R/turso.R` (credential path resolution, if the CWD issue in step 3 is confirmed)
- Delete `app/www/turso.R`

### Verification
- Run the app locally (`shiny::runApp("app/")` and via `docker compose up --build`) and confirm library data loads correctly from Turso (check that numeric columns like `lat`/`lon` are actually numeric post-fix — e.g. via `str(library_data())` in a debug breakpoint, or confirm map markers render at correct coordinates, which would fail/misbehave if `lat`/`lon` stayed character).
- Confirm `fetch_library_data.R`, `R/migrate_services.R`, `R/backfill_historical_data.R` still work unchanged (they already source `R/turso.R` directly, so this should be a no-op for them — run each once against a test/staging Turso DB if available, or at minimum confirm no syntax/reference errors via `Rscript -e "source('R/turso.R')"`).
- Confirm local dev without env vars set, only `secret.R`/`app/secret.R` present, still resolves credentials correctly from within the Shiny app.

### Outcome (done)
Implemented exactly as planned: `app/www/functions.R:2` now sources `here("R", "turso.R")` instead of `www/turso.R`; `app/www/turso.R` deleted; `load_turso_credentials()` in `R/turso.R` updated to resolve `secret.R` via `here::here("secret.R")` / `here::here("app", "secret.R")` instead of bare relative paths — confirmed by direct testing that the old relative-path check would have broken (`file.exists("app/secret.R")` resolves to the wrong path when CWD is already `app/`), even though it happened to work by accident before since a root-level `secret.R` also exists.

**Verified in a rebuilt Docker container**:
- App boots cleanly, loads all 719 libraries with `lat`/`lon` correctly typed as `numeric` and `id` as `integer` (confirming the consolidated client's `type.convert()` step is now applied, unlike the old `app/www/turso.R` copy which left everything as character).
- Full test suite still passes: `FAIL 0 | WARN 2 | SKIP 0 | PASS 31`.
- `R/turso.R` still sources cleanly from the repo root with all 5 expected functions present (`convert_to_https`, `load_turso_credentials`, `parse_turso_query_result`, `turso_execute`, `turso_query`), confirming `fetch_library_data.R`/`R/migrate_services.R`/`R/backfill_historical_data.R` are unaffected.
- Credential resolution confirmed working both from the repo root and from `app/` as CWD (matching the real Shiny app's actual invocation, where renv is already active in the R process before Shiny changes into `app/`).

**Unplanned but necessary fix along the way**: rebuilding the Docker image from a clean cache exposed that Plan 3's `renv.lock` merge had left an internally inconsistent lockfile — it recorded `testthat` (added in Plan 3) but pinned `rlang` at `1.1.5`, while `testthat`'s own CRAN `DESCRIPTION` requires `rlang >= 1.1.6`, so a from-scratch `renv::restore()` failed outright (`namespace 'rlang' 1.1.5 is being loaded, but >= 1.1.6 is required`). This had gone unnoticed in Plan 3 because that container reused an already-partially-installed library where the newer `rlang` was present despite the lockfile disagreeing. Fixed by downloading the exact CRAN tarballs for `cli` 3.6.6, `evaluate` 1.0.5, `jsonlite` 2.0.0, and `rlang` 1.3.0 (the versions `renv` itself had already resolved as necessary during Plan 3's install log, just never captured back into the lockfile) and bumping only their `Version` fields via an exact-match text substitution — a 4-line diff, re-verified as valid JSON before rebuilding. This also means the two `docker compose build` runs during this plan took ~33 minutes each (full from-scratch package compilation on a resource-shared host) since the lockfile change invalidated Docker's layer cache both times.

---

## PLAN 5 — Batch the N+1 Turso writes

### Problem
`fetch_library_data.R` writes one row at a time to Turso via `turso_execute()` in three separate loops:
- Libraries: `fetch_library_data.R:351-364` (~one HTTP call per library, thousands of libraries)
- Services: `fetch_library_data.R:369-375` (~one HTTP call per service record)
- Schedules: `fetch_library_data.R:435-446` (~one HTTP call per schedule record, runs **daily**)

Turso's `/v2/pipeline` endpoint natively accepts multiple statements in a single request's `requests` array (see `R/turso.R:146-167`), but every current call sends exactly one.

### Fix approach
Add a batched execute function to `R/turso.R` alongside the existing `turso_execute()` (don't replace it — other call sites like `R/migrate_services.R`/`R/backfill_historical_data.R` use single-statement execute and can stay as-is unless they have the same loop pattern, worth a quick check but not required for this plan).

1. **New function `turso_execute_batch(statements, batch_size = 200)`** in `R/turso.R`, where `statements` is a list of `list(sql = ..., params = ...)`:
   - Chunk `statements` into groups of `batch_size` (Turso's HTTP payload has practical size limits; 200 is a reasonable starting point, tune based on actual payload size for the largest table — schedules).
   - For each chunk, build a single `request_body$requests` list with one `type = "execute"` entry per statement (reusing the existing arg-encoding logic at `R/turso.R:151-160`, factored into a small helper `build_execute_request(sql, params)` returning the `list(type="execute", stmt=list(...))` shape).
   - POST once per chunk via the existing `request()`/`req_perform()` pattern (lines 170-179).
   - Parse `result$results` as a **list**, iterating per-statement to check `result$results[[i]]$error` and collect `affected_row_count`, instead of assuming a single result at index 1 (current code at lines 182-199 only looks at `result$results[[1]]`).
   - Propagate a clear error if any statement in the batch fails (include which row/index failed, since a bare "Turso execute error" for a 200-statement batch would be hard to debug otherwise).

2. **Update the three write loops in `fetch_library_data.R`** to build a `statements` list via `purrr::map` (already imported) instead of a `for` loop with per-row `turso_execute()`:
   ```r
   library_statements <- purrr::pmap(libraries, function(id, library_branch_name, lat, lon, city_name,
                                                          library_url, library_phone, library_email,
                                                          library_address, ...) {
     list(
       sql = "INSERT INTO libraries (id, library_branch_name, lat, lon, city_name,
                                     library_url, library_phone, library_email,
                                     library_address) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
       params = list(id, library_branch_name, lat, lon, city_name,
                     library_url, library_phone, library_email, library_address)
     )
   })
   turso_execute_batch(library_statements)
   ```
   Apply the same pattern to the service-write loop (369-375) and the schedule-write loop (435-446).

3. Keep the two upfront single-statement deletes (`DELETE FROM library_services`, `DELETE FROM libraries`, lines 344-348) as individual `turso_execute()` calls — no benefit to batching a single statement.

### Files to modify
- `R/turso.R` — add `turso_execute_batch()` (and optionally factor out the shared request-building helper used by both `turso_query`/`turso_execute`/`turso_execute_batch`).
- `fetch_library_data.R` — replace the three `for` loops (351-364, 369-375, 435-446) with statement-building + a single `turso_execute_batch()` call each.

### Verification
- Run `UPDATE_TYPE=both Rscript fetch_library_data.R` against a real (or staging) Turso database and confirm row counts written match `nrow(libraries)`/`nrow(library_services)`/`nrow(schedules)` exactly, same as today's per-row output messages already report.
- Time the run before/after to confirm the expected latency improvement (this is the actual point of the change — capture a rough before/after wall-clock number for the weekly "both" run and the daily "schedules" run).
- Test the error path deliberately (e.g. temporarily inject a bad statement into one batch) and confirm the new per-statement error reporting correctly identifies the failing row rather than failing opaquely.
- Confirm the existing `warning()`-only failure handling (`fetch_library_data.R:379-382`) still wraps the new batched call the same way — no change needed there for this plan (that's Plan 10's concern).

### Outcome (done)
Added `turso_execute_batch(statements, batch_size = 200)` to `R/turso.R`, plus two small shared helpers (`build_turso_args()`, `build_execute_request()`) factored out and reused by `turso_query()`, `turso_execute()`, and the new batch function — eliminating the previously-duplicated request-building block across all three. Statements are chunked in groups of 200 to stay within practical HTTP payload limits; each chunk is one `/v2/pipeline` POST with N statements in its `requests` array. Per-statement errors are caught and reported with their 1-indexed position within the batch (e.g. `"Turso batch execute error on statement 2 of 3: ..."`), verified via a local logic test against a synthetic response (no network needed for this check).

Updated all three write loops in `fetch_library_data.R` (libraries, services, schedules) to build a `statements` list via `purrr::pmap()` and call `turso_execute_batch()` once, replacing the per-row `for` loops.

**Verified against the real production Turso database** (there is no separate staging DB — running the real pipeline was the only way to get genuine end-to-end confidence, confirmed with the user before proceeding since this writes to shared infrastructure): `UPDATE_TYPE=both Rscript fetch_library_data.R` completed in **5m44s**, writing 719 libraries, 11,383 service records, and 1,519 schedule records — all three counts independently re-verified against Turso afterward with `SELECT COUNT(*)` queries, matching exactly. No errors, SQLite backup also completed correctly. (No isolated "before" timing exists for direct before/after comparison, since running the old per-row version against production twice wasn't worth the extra write load — but eliminating ~13,600 individual HTTP round-trips down to ~68 batched POSTs, at 200 statements each, is the structural win regardless of the exact wall-clock delta on any given day, which is also affected by network conditions and the Kirjastot.fi API's own response time for the schedule-fetching phase.)

Left `R/migrate_services.R` and `R/backfill_historical_data.R` untouched even though they have the same per-row `turso_execute()` loop pattern — out of scope for this plan (one-off migration/backfill scripts, not part of the recurring daily/weekly pipeline), flagged here as a candidate for the same treatment if those scripts are ever run again at scale.

---

## PLAN 6 — Remove the orphaned `app/renv.lock`

### Problem (revised after investigation — smaller than originally scoped)
The original suggestion was to "sync" two out-of-sync `renv.lock` files. Investigation found this framing was wrong: **`app/renv.lock` is completely inert.** It has no accompanying `.Rprofile` or `renv/` directory in `app/` to activate it as an renv project, and nothing in the Dockerfile or GitHub Actions workflows ever references it:
- `Dockerfile:22-26` copies and restores only root `renv.lock`/`.Rprofile`/`renv/activate.R`/`renv/settings.json`.
- `.github/workflows/fetch_data.yml:35` and `.github/workflows/check_library_urls.yml:25` both cache/restore keyed only on root `renv.lock`.
- The only live renv project in the repo is rooted at the repo root (`.Rprofile` → `source("renv/activate.R")`).

Git history confirms `app/` was originally the entire project root at an earlier point in the repo's life (both lockfiles share identical early commit history), and the two were left to drift independently after the repo was restructured — 41 of 69 shared packages have different pinned versions between the two files, and `app/renv.lock` is missing 18 packages the root needs (SQLite/DBI, leaflet, spatial packages, httr, shinyjs, tidyr) while carrying one the root doesn't (`otel`, seemingly unused — confirm via repo-wide grep before removal).

### Fix approach
There is nothing to "sync" — `app/renv.lock` should simply be deleted, since it plays no role in local dev, Docker build, or CI.

1. Grep the repo for any reference to `otel`/`library(otel)` to confirm it's genuinely unused (the earlier survey found no call sites, but do a final check before deleting the lockfile that pins it).
2. Delete `app/renv.lock`.
3. Confirm no documentation (`CLAUDE.md`, `README`) references `app/renv.lock` as a thing to maintain — update if so.

### Files to modify
- Delete `app/renv.lock`.

### Verification
- `docker compose up --build` still succeeds (proves the Dockerfile's restore path is genuinely unaffected).
- `git grep app/renv.lock` returns nothing after the change.
- Local `renv::restore()` at the project root still works as before (this plan doesn't touch the root lockfile at all).

### Outcome (done)
Deleted `app/renv.lock` via `git rm`. Re-confirmed before deleting: no `otel` usage anywhere in tracked `.R` files, no `app/.Rprofile` or `app/renv/` directory, no documentation references.

**Verified**: `docker compose up --build` still succeeds (fast — cache hit through the `renv::restore()` layer, only the final `COPY . .` layer changed, confirming this file was never part of the build path); app boots and serves HTTP 200; full test suite still passes (31/31); `renv::status()` at the root shows the same pre-existing, unrelated state as before (the `otel` transitive dependency note and R-version mismatch note) — nothing new or worse. `git grep app/renv.lock` returns only the plan documents' own prose describing the removed file, no code or config references.

---

## PLAN 7 — Accessibility pass

### Problem
Four concrete gaps found:
1. Icon-only clear buttons have `title` but no `aria-label`.
2. Map marker status is color-only (fails WCAG 1.4.1).
3. Dynamic geolocation error alert lacks `role="alert"`.
4. `update_map_for_nearest`'s color mapping is incomplete relative to the legend (also a correctness bug, not just a11y).

### Fix approach

**1. `aria-label` on clear buttons** — `app/ui.R:168-170` and `179-181`:
```r
actionButton("clear_library", label = HTML("&times;"),
  class = "btn btn-link p-0 clear-select-btn",
  title = "Clear library selection",
  `aria-label` = "Clear library selection")
```
Same pattern for `clear_service` (line 179-181), using "Clear service selection".

**2. Non-color status differentiation on markers** — the legend (`app/server.R:406-419`) defines 4 canonical states (`Open`, `Self`/Self-service, `ClosedNow`/Closed, `ClosedDay`/Closed for the whole day) with colors from `app/www/variables.R`. Since `leaflet::addCircleMarkers` doesn't support per-marker icon shapes as easily as `addMarkers` with custom icons, the pragmatic fix is either:
   - Vary marker **radius or border style** in addition to color (e.g. open = solid border, closed = dashed border) — achievable via the `weight`/`opacity`/`fillOpacity` params already used in the `addCircleMarkers` calls (`server.R:347-354`, `549-553`).
   - Or add a small glyph/label inside the popup (already textual) and accept that at-a-glance map color is supplemented rather than replaced — the popup and legend already carry the text label, so the main gap is the marker itself. Recommend the border-style approach as the more meaningful fix; confirm feasibility by checking `addCircleMarkers`' supported style params before committing to a specific visual treatment.

**3. `role="alert"` on the geolocation error div** — `app/server.R:581-585`:
```r
output$geolocation_error_ui <- renderUI({
  req(input$geolocation_error)
  div(class = "alert alert-danger", role = "alert",
    style = "margin: 10px 0; padding: 10px;",
    icon("exclamation-triangle"), " ", input$geolocation_error)
})
```

**4. Fix `update_map_for_nearest`'s incomplete color mapping** — `app/server.R:549-553` currently:
```r
color = ~ case_when(
  open_status == "Open" ~ chosen_colors$Open,
  open_status == "Self-service" ~ chosen_colors$Self,
  TRUE ~ chosen_colors$Unknown
),
```
Replace with the full 4-branch version already used in the main map render (`server.R:348-353`), for consistency even though upstream filtering (`server.R:481-482`) currently means `ClosedNow`/`ClosedDay` shouldn't appear in this code path today — making it robust in case that upstream filter ever changes:
```r
color = ~ case_when(
  open_status == "Open"                              ~ chosen_colors$Open,
  open_status == "Self-service"                      ~ chosen_colors$Self,
  open_status %in% c("Closed", "Temporarily closed") ~ chosen_colors$ClosedNow,
  open_status == "Closed for the whole day"          ~ chosen_colors$ClosedDay,
  TRUE                                               ~ chosen_colors$Unknown
),
```

### Files to modify
- `app/ui.R` (clear button `aria-label`s, lines 168-170, 179-181)
- `app/server.R` (geolocation alert `role="alert"` at 581-585; marker color fix at 549-553; marker style differentiation wherever `addCircleMarkers` is called, ~347-354 and ~549-554)

### Verification
- Screen reader spot-check (VoiceOver/NVDA or browser accessibility inspector) confirms clear buttons announce meaningfully.
- Trigger a geolocation error (deny permission) and confirm the alert is announced by a screen reader without requiring focus to move to it.
- Visually confirm markers are distinguishable without relying on color alone (e.g. temporarily simulate color-blindness via browser dev tools' vision-deficiency emulation).
- Confirm "Find Nearest" still renders correctly with the corrected color mapping (no visual regression for the common Open/Self-service case).

---

## PLAN 8 — Harden Cloud Run secrets

### Problem
`.github/workflows/deploy_shiny_app.yml`'s deploy step passes three secrets via `--set-env-vars`, landing them in plaintext in the Cloud Run revision configuration (visible via `gcloud run services describe` to anyone with read access to the service):
```yaml
--set-env-vars TURSO_DATABASE_URL=${{ secrets.TURSO_DATABASE_URL }},TURSO_AUTH_TOKEN=${{ secrets.TURSO_AUTH_TOKEN }},CARTO_API_KEY=${{ secrets.CARTO_API_KEY }}
```

### Fix approach
Migrate to Secret Manager-backed `--set-secrets`, which Cloud Run resolves at container start without exposing values in the revision's plaintext config.

1. **Create Secret Manager secrets** (one-time, manual or scripted — this is infrastructure setup, not a code change, and needs to happen against the real `bibliostatus-app` GCP project, so confirm before running any `gcloud secrets create` commands):
   ```bash
   echo -n "$TURSO_DATABASE_URL" | gcloud secrets create turso-database-url --data-file=- --project=bibliostatus-app
   echo -n "$TURSO_AUTH_TOKEN" | gcloud secrets create turso-auth-token --data-file=- --project=bibliostatus-app
   echo -n "$CARTO_API_KEY" | gcloud secrets create carto-api-key --data-file=- --project=bibliostatus-app
   ```
2. **Grant the deploying service account access**: `github-deploy@bibliostatus-app.iam.gserviceaccount.com` needs `roles/secretmanager.secretAccessor` on each of the 3 secrets:
   ```bash
   for secret in turso-database-url turso-auth-token carto-api-key; do
     gcloud secrets add-iam-policy-binding "$secret" \
       --member="serviceAccount:github-deploy@bibliostatus-app.iam.gserviceaccount.com" \
       --role="roles/secretmanager.secretAccessor" \
       --project=bibliostatus-app
   done
   ```
3. **Update the deploy workflow** (`.github/workflows/deploy_shiny_app.yml`, the `gcloud run deploy` step) — replace `--set-env-vars ...` with `--set-secrets`:
   ```yaml
   --set-secrets TURSO_DATABASE_URL=turso-database-url:latest,TURSO_AUTH_TOKEN=turso-auth-token:latest,CARTO_API_KEY=carto-api-key:latest
   ```
4. Once confirmed working, the corresponding GitHub Actions secrets (`TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN`, `CARTO_API_KEY`) can eventually be removed if nothing else in CI reads them directly (check `fetch_data.yml` — it likely needs its own copies as env vars for the data-fetch job, which is separate from the deploy job, so those probably stay; only the deploy workflow's usage changes).

### Files to modify
- `.github/workflows/deploy_shiny_app.yml` (the `--set-env-vars` → `--set-secrets` line)
- GCP infrastructure (Secret Manager secrets + IAM bindings) — done via `gcloud` CLI, not a file in the repo.

### Verification
- Trigger a manual deploy (`gh workflow run deploy_shiny_app.yml`) and confirm it succeeds.
- `gcloud run services describe bibliostatus-app --project=bibliostatus-app` and confirm the env vars section no longer shows plaintext values, while the secret-reference format is shown instead.
- Confirm the running app still connects to Turso and renders the Carto basemap correctly (visit the live URL, check both the map tiles load and library data populates) — this is the functional smoke test that the secret resolution actually works at runtime.

---

## PLAN 9 — Externalize hardcoded override tables

### Problem
`fetch_library_data.R` embeds three data-quality patch tables directly in application code:
1. Lat/lon overrides for 8 libraries (lines 54-76), keyed by `id`.
2. A ~110-branch URL override `case_when` (lines 84-195), keyed by `id`, with some entries dated (`# Fixed broken URLs (2026-02-15)` at line 156 marking a batch).
3. An exclusion list of 4 library IDs with no separate address (lines 197-202, filtered out entirely).

These will keep growing and are painful to review/diff as inline code.

### Fix approach
Introduce a `data/` directory at the repo root (none currently exists) holding the override data as CSV, loaded at the top of `fetch_library_data.R`.

1. **Create `data/library_coordinate_overrides.csv`**:
   ```csv
   id,lat,lon,comment
   85322,62.78559,22.84204,Seinäjoen pääkirjasto, Apila-kirjasto
   85793,59.92259,20.91381,Kökar
   86436,60.03090,20.38677,Föglö
   86597,64.92256,25.55812,Kempeleen Linnakankaan kirjasto
   86725,61.56385,25.18183,Kuhmoisten kirjasto
   86775,62.78629,22.84219,Seinäjoen pääkirjasto, Aallon kirjasto
   86784,61.68672,27.27313,Mikkelin pääkirjasto
   86787,61.51729,26.47860,Pertunmaan lähikirjasto
   ```
   (Comment values containing commas need proper CSV quoting — use `readr::write_csv` to generate this correctly rather than hand-typing.)

2. **Create `data/library_url_overrides.csv`** with columns `id, url, comment`, migrating all ~110 entries from lines 84-195. While migrating, **fix the known defect** at the current line 139 (id 86071) which has a leading space bug in the URL literal (`' https://loisto...'`) — clean it up rather than preserving the bug.

3. **Create `data/library_exclusions.csv`** with columns `id, comment`, migrating the 4-ID exclusion list (lines 197-202).

4. **Replace the inline `case_when` blocks in `fetch_library_data.R`** with a join-based approach:
   ```r
   coord_overrides <- read_csv(here("data/library_coordinate_overrides.csv"), show_col_types = FALSE)
   url_overrides   <- read_csv(here("data/library_url_overrides.csv"), show_col_types = FALSE)
   exclusions      <- read_csv(here("data/library_exclusions.csv"), show_col_types = FALSE)

   libraries <- libraries %>%
     left_join(coord_overrides %>% select(id, lat_override = lat, lon_override = lon), by = "id") %>%
     mutate(
       lat = coalesce(lat_override, lat),
       lon = coalesce(lon_override, lon)
     ) %>%
     select(-lat_override, -lon_override) %>%
     left_join(url_overrides %>% select(id, url_override = url), by = "id") %>%
     mutate(library_url = coalesce(url_override, library_url)) %>%
     select(-url_override) %>%
     filter(!is.na(lat) & !is.na(lon) & !id %in% exclusions$id) %>%
     select(-c(street_address, zip_code))
   ```

### Files to modify
- Add `data/library_coordinate_overrides.csv`, `data/library_url_overrides.csv`, `data/library_exclusions.csv`.
- `fetch_library_data.R` — replace lines 54-76 and 84-202 with the CSV-loading + join/coalesce logic above.

### Verification
- Run `UPDATE_TYPE=both Rscript fetch_library_data.R` and diff the resulting `libraries` table (lat/lon/url columns, and row count after exclusion) against a snapshot taken before this change — should be byte-for-byte identical except for the one intentionally-fixed leading-space URL bug.
- Confirm the 4 excluded library IDs are still excluded and the 8 coordinate overrides and ~110 URL overrides still apply correctly.

---

## PLAN 10 — Smaller code-quality cleanups

### Problem (four independent sub-items, batch together since each is small)

**10a. Duplicated Turso/SQLite fallback boilerplate** — `app/www/functions.R:24-84`, three near-identical `tryCatch(turso_query(...), error=...) ; fallback to SQLite` blocks for `fetch_libraries`, `fetch_schedules`, `fetch_library_services`.

**10b. Duplicated popup-HTML building** — `app/server.R:356-385` (main map) and `555-570` (nearest-libraries map) build near-identical Leaflet popup HTML via `paste`/`if_else`, differing only in whether an "Hours:" line or a "Distance:" line is included.

**10c. Silent pipeline write failures** — `fetch_library_data.R:341-382`, Turso write failures are caught and only `warning()`'d; the script exits 0 regardless, so the GitHub Actions run reports success even if the Turso write failed (SQLite backup still gets written, masking the production DB issue).

**10d. Scattered magic numbers** — mobile marker radii (`server.R:355,536,554`), popup width (`server.R:399-400`), zoom level and the "≤2 libraries" threshold (`server.R:422,427`), nearest-library count (`server.R:499`), and three different geolocation timeouts in `app/ui.R:96,105,134` with differing `enableHighAccuracy`/`maximumAge` values that are semantically intentional but undocumented.

### Fix approach

**10a** — add a shared helper in `app/www/functions.R`:
```r
with_turso_fallback <- function(turso_query_fn, sqlite_query_fn, context) {
  tryCatch({
    turso_query_fn()
  }, error = function(e) {
    warning(sprintf("Turso failed (%s), using SQLite: %s", context, e$message))
    sqlite_query_fn()
  })
}
```
Refactor all three functions (`fetch_libraries`, `fetch_schedules`, `fetch_library_services`) to call this with closures for their respective Turso/SQLite query logic, preserving each function's exact current SQL (including the parameterized `date` filter in `fetch_schedules`).

**10b** — extract a shared, vectorized popup-builder in `app/server.R` (or move to `functions.R`):
```r
build_library_popup <- function(library_url, library_branch_name, library_address,
                                 open_status, lat, lon,
                                 opening_hours = NULL, distance_display = NULL) {
  name_html <- if_else(!is.na(library_url),
    paste0("<b><a href='", library_url, "' target='_blank'>", library_branch_name, "</a></b>"),
    paste0("<b>", library_branch_name, "</b>"))
  directions <- sprintf(
    "📍 <a href='https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f' target='_blank' style='color: #C1272D; font-weight: bold;'>Get Directions</a>",
    lat, lon)
  extra <- if (!is.null(opening_hours)) {
    paste0("<br>", if_else(!is.na(opening_hours), paste("<b>Hours: </b>", opening_hours), "<b>Hours: </b>NA"))
  } else if (!is.null(distance_display)) {
    paste0("<br><b>Distance: </b>", distance_display)
  } else ""
  paste0(name_html, "<br>", library_address, "<br><b>Status: </b>", open_status, extra, "<br>", directions)
}
```
Call from both `server.R:356-385` (passing `opening_hours=`) and `555-570` (passing `distance_display=`), keeping this vector-safe since it's used inside a `~` formula over a data frame in `addCircleMarkers`.

**10c** — decide and implement a failure policy: after the `turso_success` check (`fetch_library_data.R:393-395`), replace the bare `warning()` with a hard failure so CI surfaces it:
```r
if (!turso_success) {
  stop("Turso write failed - SQLite backup was written, but production database was NOT updated. Investigate before the next scheduled run.")
}
```
This makes the GitHub Actions job fail visibly instead of silently degrading. Decide whether hard failure is preferred over a softer notification (e.g. a GitHub issue or Slack ping) — hard failure is the simpler, lower-effort default and is recommended unless active notification is wanted.

**10d** — introduce named constants near the top of `app/server.R` and `app/ui.R`:
```r
# app/server.R
MOBILE_MARKER_RADIUS <- 10
DESKTOP_MARKER_RADIUS <- 8
MOBILE_NEAREST_MARKER_RADIUS <- 12
DESKTOP_NEAREST_MARKER_RADIUS <- 10
DEFAULT_ZOOM_LEVEL <- 11
SINGLE_LIBRARY_ZOOM_THRESHOLD <- 2
MOBILE_NEAREST_COUNT <- 3
DESKTOP_NEAREST_COUNT <- 5
```
```js
// app/ui.R (JS block)
const STARTUP_GEO_TIMEOUT_MS = 8000;        // fast/cheap fix on load
const STARTUP_GEO_FALLBACK_MS = 9000;       // give up and use Helsinki
const FIND_NEAREST_GEO_TIMEOUT_MS = 10000;  // user-initiated, wait longer for precision
```
Replace each inline literal with its named constant, preserving exact current values (this is a pure refactor, no behavior change).

### Files to modify
- `app/www/functions.R` (10a)
- `app/server.R` (10b, 10d)
- `fetch_library_data.R` (10c)
- `app/ui.R` (10d)

### Verification
- 10a/10b: confirm `fetch_libraries()`/`fetch_schedules()`/`fetch_library_services()` and both popup call sites still produce byte-identical output before/after refactor (manual diff of rendered popups, or a quick snapshot test if Plan 3's test suite is already in place by this point).
- 10c: deliberately break Turso credentials temporarily in a test run and confirm the script now exits non-zero (check `$?` after `Rscript fetch_library_data.R`) while SQLite backup still gets written.
- 10d: visual smoke test on both desktop and mobile viewport sizes to confirm marker sizes and behavior are unchanged after the constant extraction.

---

## PLAN 11 — Head script races Shiny's own JS load (found during Plan 1 verification, needs further planning)

### Problem
While verifying Plan 1 in a live browser (headless Chromium via Playwright), every page load throws a console error:
```
Shiny.setInputValue is not a function
```
This is a **pre-existing bug**, unrelated to Plan 1's changes (confirmed via `git diff` — `app/ui.R` was untouched by Plan 1).

### Root cause (verified in `app/ui.R:55-143`)
The `header = tags$head(...)` block (`app/ui.R:55-143`) contains an inline `tags$script(HTML("..."))` (lines 59-137) that calls `Shiny.addCustomMessageHandler(...)` at its top level, unconditionally, as soon as the script tag is parsed:
```r
tags$script(HTML(
  "
    Shiny.addCustomMessageHandler('checkMobile', function(message) { ... });   # line 61
    ...
    $(document).on('shiny:sessioninitialized', function() { ... });             # line 77
    ...
    Shiny.addCustomMessageHandler('requestGeolocation', function(message) { ... }); # line 109
  "
))
```
Because this script lives in `<head>`, it can execute before Shiny's own JS bundle (usually emitted later, near the end of `<body>`, per standard Shiny/htmltools dependency injection) has attached the `Shiny` global's methods — so `Shiny.addCustomMessageHandler` throws `is not a function` at line 61 (and would also affect line 109's registration).

**This is non-fatal in practice**: verified via browser automation that `input$is_mobile` and the startup-geolocation flow both still end up set correctly, because the `$(document).on('shiny:sessioninitialized', ...)` handler (registered via jQuery, which loads independently of Shiny's own readiness) re-does the `is_mobile`/`is_dark_mode` reporting once Shiny is actually ready (lines 77-106). So the app is not currently broken by this — but:
- The `checkMobile` custom message handler (line 61-64) registration itself may silently fail to ever register, meaning if `Shiny.addCustomMessageHandler('checkMobile', ...)` is invoked from the server side via `session$sendCustomMessage("checkMobile", ...)` at any point, nothing would happen (no call sites currently found via a first pass, but not exhaustively verified — needs a repo-wide grep for `checkMobile`/`sendCustomMessage` before concluding it's dead code vs. latent bug).
- The `requestGeolocation` handler (line 109-136), which backs the "Find Nearest" button, is subject to the exact same race — if it fails to register for the same reason, "Find Nearest" could silently do nothing on some page loads. This needs to be confirmed/ruled out, since unlike `checkMobile` it has an active, user-facing call site (visible in `app/server.R`'s use of `session$sendCustomMessage("requestGeolocation", ...)` for the Find Nearest button).

### Status
Not yet planned in detail — needs investigation before a fix approach is written:
1. Confirm via repo-wide grep whether `checkMobile` is ever actually invoked from the server (if not, it may be dead code to remove rather than fix).
2. Confirm whether `requestGeolocation`'s handler registration is actually failing intermittently (race-dependent — may depend on network/cache conditions affecting Shiny's JS load time) or reliably succeeds in practice despite the console error (e.g. if Shiny's core JS happens to load fast enough in most real-world conditions, only failing in colder-cache/headless scenarios like the one that surfaced it here).
3. Once the actual blast radius is known, the likely fix is straightforward: move the `Shiny.addCustomMessageHandler` registrations (and the `$(document).on('shiny:sessioninitialized', ...)` block, which doesn't need to move but is fine where it is) out of `tags$head` and into a location guaranteed to run after Shiny's JS is ready — e.g. wrap the whole script body in `$(document).on('shiny:sessioninitialized', function() { ... })`, or move the `<script>` tag to run at the end of the page body instead of the head.

### Files likely involved
- `app/ui.R` (lines 55-143)
- `app/server.R` (wherever `session$sendCustomMessage("requestGeolocation", ...)` and/or `"checkMobile"` are called — needs to be located)

### Verification (once planned)
- Repeat the headless-browser page load used to surface this bug and confirm the console error no longer appears.
- Confirm "Find Nearest" still works correctly after the fix (this is the one user-facing feature that could be silently affected).

---

## Execution order note

Recommended sequence given dependencies:
1. **Plan 1** (bug fixes) — independent, highest user-visible value. ✅ Done.
2. **Plan 3** (tests) — write the cascade regression test against the Plan 1 fix while it's fresh. ✅ Done (31/31 passing; service-label-resync test deferred to shinytest2, see Plan 3's Outcome).
3. **Plan 2** (sidebar CSS) — independent, small, needs in-browser verification. ✅ Done (CSS cleanup applied; overlap itself not reproducible in testing, needs user confirmation).
4. **Plan 4** (Turso client consolidation) — do before Plan 5, since Plan 5 benefits from the shared request-building helper this consolidation can produce. ✅ Done (verified: correct numeric typing, 31/31 tests pass, credentials resolve from both CWD contexts; also fixed an internally inconsistent renv.lock left over from Plan 3).
5. **Plan 5** (batch writes) — depends conceptually on Plan 4 being in place first (shared helpers), though not strictly blocking. ✅ Done (verified against production Turso: 719 libraries + 11,383 services + 1,519 schedules written and confirmed, 31/31 tests pass).
6. **Plan 6** (delete orphaned lockfile) — trivial, no dependencies. ✅ Done (verified: build still succeeds, 31/31 tests pass, no references remain).
7. **Plan 9** (externalize override tables) — independent.
8. **Plan 10** (small cleanups) — do last among code changes since 10a/10b touch the same functions Plans 4/5 also modify; avoids merge friction.
9. **Plan 7** (accessibility) — independent, can slot in anywhere.
10. **Plan 8** (secrets hardening) — independent, involves GCP infrastructure changes outside the codebase; needs explicit sign-off before running `gcloud` commands against production.
11. **Plan 11** (head script race) — found during Plan 1's live verification; needs further investigation (see Status above) before it can be scheduled with the others.
