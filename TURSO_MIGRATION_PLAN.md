# BiblioStatus Turso Migration Plan

## Context

BiblioStatus currently uses a local SQLite database that is overwritten daily with fresh data from the Kirkanta API. This migration will enable historical data retention, cloud database benefits, and more efficient update strategies.

**Goals:**
1. Migrate from SQLite to Turso (cloud SQLite) with SQLite fallback
2. Preserve all historical schedule data for year-end analysis
3. Backfill data from 2026-01-01 to present (46 days)
4. Separate update strategies: library metadata (weekly) vs schedules (daily)
5. Detect orphaned schedule data (schedules without matching libraries)
6. Keep manual corrections in R code (URLs, coordinates)

**Data Characteristics:**

*Library Metadata (slow-changing):*
- Names, coordinates, URLs, phone/email, services
- ~720 libraries total
- Includes 50+ manual URL corrections + 8 coordinate fixes in R code
- Changes infrequently → **Update weekly**
- No historical versioning needed (overwrite on update)

*Schedule Data (fast-changing):*
- Opening hours and status for each library
- Changes daily, multiple periods per day possible
- Core real-time data → **Update daily**
- Historical records preserved indefinitely

## Recommended Approach: Turso Primary + SQLite Fallback

**Architecture:**
```
┌─────────────────────────────────────────────┐
│  Data Fetch (GitHub Actions)               │
│  ┌─────────────────────────────────────┐   │
│  │ Daily (2 AM):                       │   │
│  │ - Fetch schedules                   │   │
│  │ - Write to Turso (append)           │   │
│  │ - Write to SQLite (overwrite)       │   │
│  │ - Detect orphaned data              │   │
│  └─────────────────────────────────────┘   │
│  ┌─────────────────────────────────────┐   │
│  │ Weekly (Sunday 2 AM):               │   │
│  │ - Fetch library metadata            │   │
│  │ - Apply manual corrections          │   │
│  │ - Write to Turso (replace)          │   │
│  │ - Write to SQLite (replace)         │   │
│  └─────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│  Shiny App (Cloud Run)                      │
│  1. Try read from Turso                     │
│  2. If Turso fails → read from SQLite       │
│  3. Display data (seamless to user)         │
└─────────────────────────────────────────────┘
```

**Benefits:**
- Reduced API calls (library metadata fetched 52x/year instead of 365x/year)
- Historical data preserved in Turso for analytics
- SQLite fallback ensures 100% uptime
- Manual corrections remain in Git version control
- Orphaned data detection prevents data quality issues

## Implementation Plan

### Phase 1: Turso Setup & Schema (Day 1)

**A. Create Turso Database**
```bash
turso db create bibliostatus-db --location ams  # Amsterdam (close to Finland)
turso db show bibliostatus-db
turso db tokens create bibliostatus-db
```

**B. Create Schema**
```sql
-- Libraries table (no historical versioning)
CREATE TABLE libraries (
    id INTEGER PRIMARY KEY,
    library_branch_name TEXT NOT NULL,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    city_name TEXT,
    library_url TEXT,
    library_phone TEXT,
    library_email TEXT,
    library_services TEXT,
    library_address TEXT,
    updated_at TEXT DEFAULT (datetime('now'))
);

-- Schedules table (with historical preservation)
CREATE TABLE schedules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL,
    date TEXT NOT NULL,
    from_time TEXT,
    to_time TEXT,
    status_label TEXT,
    inserted_at TEXT DEFAULT (datetime('now')),
    UNIQUE(library_id, date, from_time, to_time)  -- Prevent duplicates
);

-- Indexes for performance
CREATE INDEX idx_schedules_library_date ON schedules(library_id, date);
CREATE INDEX idx_schedules_date ON schedules(date);
CREATE INDEX idx_libraries_id ON libraries(id);
```

**Schema Changes from SQLite:**
- Renamed `from` → `from_time`, `to` → `to_time` (avoid SQL reserved words)
- Added `id` primary key to schedules for historical tracking
- Added `updated_at` to libraries for change tracking
- Added UNIQUE constraint to prevent duplicate schedule records
- Libraries table has no `id` autoincrement (uses API-provided IDs)

**C. Add GitHub Secrets**
```
TURSO_DATABASE_URL=libsql://bibliostatus-db-xxx.turso.io
TURSO_AUTH_TOKEN=eyJhbGc...
```

### Phase 2: Create Helper Functions (Day 1-2)

**Create `/home/antti/VSCode/BiblioStatus/R/turso.R`** (based on Gallery pattern)

Key functions:
- `turso_query(sql, params)` - Execute SELECT queries
- `turso_execute(sql, params)` - Execute INSERT/UPDATE/DELETE
- `convert_to_https(url)` - Convert libsql:// to https://

Implementation uses `httr2` package to call Turso HTTP API (`/v2/pipeline` endpoint) with proper error handling and parameterized queries.

**Create `/home/antti/VSCode/BiblioStatus/app/www/turso.R`** (simplified app version)
- Read-only version for Shiny app
- Loads from app config

### Phase 3: Split Fetch Logic (Day 2-3)

**Modify `/home/antti/VSCode/BiblioStatus/fetch_library_data.R`**

Split into two modes:

**Mode 1: Daily Schedule Fetch** (default)
```r
if (update_type == "schedules") {
  # Fetch schedules for today
  schedules <- fetch_schedules(libraries)

  # Orphaned data detection
  orphaned <- schedules %>%
    anti_join(libraries, by = c("library_id" = "id"))

  if (nrow(orphaned) > 0) {
    warning("Found ", nrow(orphaned), " schedule records for unknown libraries!")
    # Log details for investigation
  }

  # Write to Turso (append mode)
  write_schedules_to_turso(schedules)

  # Write to SQLite (overwrite - backup only)
  con <- dbConnect(SQLite(), "app/libraries.sqlite")
  dbWriteTable(con, "schedules", schedules, overwrite = TRUE)
  dbDisconnect(con)
}
```

**Mode 2: Weekly Library Metadata Fetch**
```r
if (update_type == "libraries") {
  # Fetch library metadata
  libraries <- fetch_libraries()

  # Apply manual corrections (keep in code)
  libraries <- libraries %>%
    mutate(
      lat = case_when(
        id == 85322 ~ 22.84198, # Manual coordinate fixes
        # ... 8 coordinate corrections
        TRUE ~ lat
      ),
      library_url = case_when(
        id == 84749 ~ 'https://...', # Manual URL fixes
        # ... 50+ URL corrections
        TRUE ~ library_url
      )
    )

  # Write to Turso (replace all)
  turso_execute("DELETE FROM libraries")
  write_libraries_to_turso(libraries)

  # Write to SQLite (overwrite - backup only)
  con <- dbConnect(SQLite(), "app/libraries.sqlite")
  dbWriteTable(con, "libraries", libraries, overwrite = TRUE)
  dbDisconnect(con)
}
```

**Fallback Logic:**
Both modes include try-catch blocks that fall back to SQLite-only if Turso writes fail.

### Phase 4: Update App Functions (Day 3)

**Modify `/home/antti/VSCode/BiblioStatus/app/www/functions.R`**

```r
source("www/turso.R")

# Load Turso credentials
TURSO_DATABASE_URL <- Sys.getenv("TURSO_DATABASE_URL")
TURSO_AUTH_TOKEN <- Sys.getenv("TURSO_AUTH_TOKEN")
if (TURSO_DATABASE_URL == "" && file.exists("secret.R")) {
  source("secret.R")
}

fetch_libraries <- function() {
  # Try Turso first
  tryCatch({
    return(turso_query("SELECT * FROM libraries"))
  }, error = function(e) {
    warning("Turso failed, using SQLite: ", e$message)
  })

  # Fallback to SQLite
  con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
  data <- dbReadTable(con, "libraries")
  dbDisconnect(con)
  return(data)
}

fetch_schedules <- function() {
  today <- format(Sys.Date(), "%Y-%m-%d")

  # Try Turso first - get today's schedules
  tryCatch({
    return(turso_query(
      "SELECT library_id, date, from_time as from, to_time as to, status_label
       FROM schedules WHERE date = ?",
      list(today)
    ))
  }, error = function(e) {
    warning("Turso failed, using SQLite: ", e$message)
  })

  # Fallback to SQLite (also filter by date for consistency)
  con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
  data <- dbGetQuery(con,
    "SELECT library_id, date, from, to, status_label
     FROM schedules WHERE date = ?",
    params = list(today)
  )
  dbDisconnect(con)
  return(data)
}
```

**Key changes:**
- Added `from_time as from` alias for backward compatibility
- Both Turso and SQLite paths filter by today's date for consistency
- Uses `dbGetQuery` with parameterized query (not `dbReadTable`) for date filtering

### Phase 5: Update GitHub Actions (Day 3-4)

**Modify `.github/workflows/fetch_data.yml`**

```yaml
name: Fetch Library Data

on:
  schedule:
    - cron: "0 2 * * *"  # Daily at 2 AM UTC (schedules)
    - cron: "0 2 * * 0"  # Sunday at 2 AM UTC (libraries)
  workflow_dispatch:
    inputs:
      update_type:
        description: 'What to update'
        required: true
        default: 'schedules'
        type: choice
        options:
          - schedules
          - libraries
          - both

jobs:
  fetch-data:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Set up R
      uses: r-lib/actions/setup-r@v2

    - name: Install dependencies
      run: |
        sudo apt-get install -y libcurl4-openssl-dev libssl-dev

    - name: Set up renv
      uses: r-lib/actions/setup-renv@v2

    - name: Determine update type
      id: update-type
      run: |
        if [ "${{ github.event_name }}" = "schedule" ]; then
          if [ "$(date +%u)" = "7" ]; then
            echo "type=both" >> $GITHUB_OUTPUT
          else
            echo "type=schedules" >> $GITHUB_OUTPUT
          fi
        else
          echo "type=${{ inputs.update_type }}" >> $GITHUB_OUTPUT
        fi

    - name: Fetch data
      env:
        TURSO_DATABASE_URL: ${{ secrets.TURSO_DATABASE_URL }}
        TURSO_AUTH_TOKEN: ${{ secrets.TURSO_AUTH_TOKEN }}
        UPDATE_TYPE: ${{ steps.update-type.outputs.type }}
      run: Rscript fetch_library_data.R

    - name: Commit SQLite backup
      run: |
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git add app/libraries.sqlite
        git commit -m "Update database $(date -u +"%Y-%m-%d %H:%M UTC")"
        git push
```

**Key changes:**
- Two cron schedules: daily for schedules, Sunday for libraries
- `UPDATE_TYPE` environment variable controls fetch mode
- Manual workflow dispatch allows choosing what to update
- Turso credentials passed via environment variables
- SQLite still committed as backup

**Modify `.github/workflows/deploy_shiny_app.yml`**

```yaml
- name: Deploy to Cloud Run
  run: |
    gcloud run deploy bibliostatus-app \
      --image ... \
      --set-env-vars TURSO_DATABASE_URL=${{ secrets.TURSO_DATABASE_URL }},TURSO_AUTH_TOKEN=${{ secrets.TURSO_AUTH_TOKEN }}
```

### Phase 6: Create Backfill Script (Day 4-5)

**Create `/home/antti/VSCode/BiblioStatus/R/backfill_historical_data.R`**

```r
#!/usr/bin/env Rscript
# Backfill historical schedules from 2026-01-01 to present
# Usage: Rscript R/backfill_historical_data.R [start_date] [end_date]

library(dplyr)
library(here)
library(httr)
library(jsonlite)
library(purrr)

source(here("R/turso.R"))

# Parse arguments
args <- commandArgs(trailingOnly = TRUE)
start_date <- if (length(args) >= 1) as.Date(args[1]) else as.Date("2026-01-01")
end_date <- if (length(args) >= 2) as.Date(args[2]) else Sys.Date() - 1

cat("Backfilling from", as.character(start_date), "to", as.character(end_date), "\n")

# Get library IDs from Turso
libraries <- turso_query("SELECT id FROM libraries")
library_ids <- libraries$id

cat("Found", length(library_ids), "libraries\n")

# Process each date
dates <- seq(start_date, end_date, by = "day")
total_dates <- length(dates)

for (date_idx in seq_along(dates)) {
  target_date <- dates[date_idx]
  date_str <- as.character(target_date)

  cat(sprintf("[%d/%d] Processing %s...\n", date_idx, total_dates, date_str))

  # Check if already exists
  existing <- turso_query(
    "SELECT COUNT(*) as count FROM schedules WHERE date = ?",
    list(date_str)
  )

  if (existing$count[1] > 0) {
    cat("  Skipping (already exists)\n")
    next
  }

  # Fetch schedules for all libraries on this date
  all_schedules <- map_dfr(library_ids, function(lib_id) {
    response <- GET(
      "https://api.kirjastot.fi/v4/schedules",
      query = list(library = lib_id, date = date_str)
    )

    if (status_code(response) != 200) return(NULL)

    data <- fromJSON(content(response, "text"), flatten = TRUE)$items
    if (length(data) == 0) return(NULL)

    # ... process schedule data (same logic as fetch_library_data.R)

    Sys.sleep(0.1)  # Rate limiting: 10 req/s
    return(schedule_df)
  })

  # Insert into Turso
  if (nrow(all_schedules) > 0) {
    for (i in 1:nrow(all_schedules)) {
      row <- all_schedules[i, ]
      turso_execute(
        "INSERT INTO schedules (library_id, date, from_time, to_time, status_label)
         VALUES (?, ?, ?, ?, ?)",
        list(row$library_id, row$date, row$from, row$to, row$status_label)
      )
    }
    cat(sprintf("  Inserted %d records\n", nrow(all_schedules)))
  }
}

cat("\nBackfill complete! Run summary:\n")
summary <- turso_query("
  SELECT
    COUNT(DISTINCT date) as total_dates,
    MIN(date) as earliest,
    MAX(date) as latest,
    COUNT(*) as total_records
  FROM schedules
")
print(summary)
```

**Execution plan:**
1. Test locally: `Rscript R/backfill_historical_data.R 2026-01-01 2026-01-07` (1 week)
2. Verify data quality in Turso CLI
3. Run full backfill: `Rscript R/backfill_historical_data.R 2026-01-01 2026-02-15`
4. Estimated time: 1-2 hours (720 libraries × 46 dates × 0.1s = ~55 min)

### Phase 7: Update Dependencies (Day 5)

```r
# In R console at project root
renv::install("httr2")
renv::snapshot()
```

Updates `renv.lock` to include httr2 and its dependencies.

## Database Schema Comparison

### SQLite (Current)
```sql
libraries: id, library_branch_name, lat, lon, city_name,
           library_url, library_phone, library_email,
           library_services, library_address

schedules: library_id, date, from, to, status_label
```

### Turso (New)
```sql
libraries: id, library_branch_name, lat, lon, city_name,
           library_url, library_phone, library_email,
           library_services, library_address, updated_at

schedules: id (PK), library_id, date, from_time, to_time,
           status_label, inserted_at
```

**Compatibility notes:**
- App queries use `from_time as from` for backward compatibility
- Libraries table structure unchanged (except added `updated_at`)
- Schedules gain historical tracking with `id` and `inserted_at`

## Update Frequency Strategy

| Data Type | Current | New | Rationale |
|-----------|---------|-----|-----------|
| Library metadata | Daily | Weekly (Sunday) | Rarely changes, reduce API calls |
| Schedule data | Daily | Daily | Core real-time data, must be fresh |
| Manual corrections | In code | In code | Version controlled, transparent |

**API call reduction:**
- Current: 720 libraries × 365 days = 262,800 library API calls/year
- New: 720 libraries × 52 weeks = 37,440 library API calls/year
- **Savings: 86% fewer library metadata API calls**

## Orphaned Data Detection

**Scenario:** Kirkanta API returns schedule for library ID that doesn't exist in libraries table

**Detection:**
```r
orphaned <- schedules %>%
  anti_join(libraries, by = c("library_id" = "id"))

if (nrow(orphaned) > 0) {
  # Send alert (GitHub Actions email notification)
  warning("Found orphaned schedule data for unknown libraries: ",
          paste(unique(orphaned$library_id), collapse = ", "))
}
```

**Action:** Email alert to `anttilennartrask@gmail.com` (same pattern as broken URL monitoring)

## Fallback Mechanism

**Read Path (App):**
```
User Request → Try Turso → Success? → Return data
                    ↓         ↓
                   Fail      Yes
                    ↓
            Try SQLite → Return data
```

**Write Path (GitHub Actions):**
```
Fetch from API → Write to Turso → Success? → Commit SQLite → Push
                      ↓              ↓
                    Always        Yes/No
                      ↓
               Write to SQLite ← Log warning if Turso failed
```

**Key principle:** SQLite always written as backup, regardless of Turso success/failure.

## Testing Plan

### Phase 1: Local Development
- [ ] Create Turso database and schema
- [ ] Test `R/turso.R` functions directly
- [ ] Run `fetch_library_data.R` locally with `UPDATE_TYPE=both`
- [ ] Verify data in Turso CLI: `turso db shell bibliostatus-db`
- [ ] Test app locally: `shiny::runApp("app")`

### Phase 2: Fallback Testing
- [ ] Break Turso credentials intentionally
- [ ] Verify app falls back to SQLite without errors
- [ ] Restore credentials and verify Turso reconnects

### Phase 3: GitHub Actions
- [ ] Add Turso secrets to GitHub
- [ ] Manual trigger: schedules only
- [ ] Manual trigger: libraries only
- [ ] Manual trigger: both
- [ ] Verify automated Sunday schedule works

### Phase 4: Backfill
- [ ] Run 1-week test backfill locally
- [ ] Query Turso to verify data quality
- [ ] Run full 46-day backfill
- [ ] Validate date coverage and record counts

### Phase 5: Production
- [ ] Deploy to Cloud Run with Turso env vars
- [ ] Test app reads from Turso
- [ ] Monitor Cloud Run logs for 24 hours
- [ ] Verify no performance degradation

## Rollback Plan

**Immediate rollback (< 1 hour):**
```bash
# 1. Remove Turso secrets from GitHub
# 2. Revert code changes
git revert <migration-commit-hash>
git push origin main

# 3. Redeploy
gh workflow run deploy_shiny_app.yml
```

**Graceful rollback:**
- Update `fetch_library_data.R` to skip Turso writes
- Update `app/www/functions.R` to skip Turso reads
- SQLite continues working (no data loss)

**Zero data loss guarantee:**
- SQLite backup maintained during entire migration
- SQLite committed to Git after every fetch
- Can reconstruct Turso from SQLite if needed

## Timeline

**Optimistic (5 days):**
- Day 1: Setup + helper functions (4h)
- Day 2: Fetch script updates (4h)
- Day 3: App updates + testing (4h)
- Day 4: GitHub Actions (2h)
- Day 5: Backfill + production (6h)

**Realistic (7-10 days):**
- Days 1-2: Development (8h)
- Days 3-4: Local testing (8h)
- Days 5-6: CI/CD setup (6h)
- Days 7-8: Backfill execution (8h)
- Days 9-10: Production testing (4h)

## Success Metrics

Post-migration validation:
- [ ] App loads library data from Turso
- [ ] App loads schedule data from Turso
- [ ] Fallback to SQLite works when Turso unavailable
- [ ] Historical data queryable (2026-01-01 to present)
- [ ] Orphaned data detection alerts working
- [ ] Weekly library updates trigger on Sunday
- [ ] Daily schedule updates trigger every day
- [ ] No performance degradation vs SQLite
- [ ] Cloud Run logs show successful Turso connections
- [ ] SQLite backup still committed daily

## Files to Create

- `/home/antti/VSCode/BiblioStatus/R/turso.R` - Turso API helper functions
- `/home/antti/VSCode/BiblioStatus/app/www/turso.R` - App-specific Turso wrapper
- `/home/antti/VSCode/BiblioStatus/R/backfill_historical_data.R` - Backfill script

## Files to Modify

- `/home/antti/VSCode/BiblioStatus/fetch_library_data.R` - Split into daily/weekly modes, add Turso writes
- `/home/antti/VSCode/BiblioStatus/app/www/functions.R` - Add Turso reads with SQLite fallback
- `/home/antti/VSCode/BiblioStatus/.github/workflows/fetch_data.yml` - Add weekly schedule, Turso env vars
- `/home/antti/VSCode/BiblioStatus/.github/workflows/deploy_shiny_app.yml` - Add Turso env vars to Cloud Run
- `/home/antti/VSCode/BiblioStatus/renv.lock` - Add httr2 dependency

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| API rate limits during backfill | Medium | 0.1s delay between requests (10 req/s) |
| Turso service downtime | Low | SQLite fallback ensures 100% uptime |
| Schema migration errors | Medium | Extensive local testing before production |
| Orphaned schedule data | Low | Automated detection + email alerts |
| Cost overrun | Very Low | Well within Turso free tier (9 GB) |

**Estimated costs:**
- Turso free tier: 9 GB storage, 1 billion row reads/month
- BiblioStatus: ~1,500 schedules/day × 365 = 547,500 rows/year
- Verdict: **Free tier sufficient for years**
