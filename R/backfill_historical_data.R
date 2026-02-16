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

cat(sprintf("=== BiblioStatus Historical Data Backfill ===\n"))
cat(sprintf("Backfilling from %s to %s\n\n", as.character(start_date), as.character(end_date)))

# Get library IDs from Turso
cat("Fetching library list from Turso...\n")
libraries <- turso_query("SELECT id FROM libraries")
library_ids <- libraries$id
cat(sprintf("Found %d libraries\n\n", length(library_ids)))

# Process each date
dates <- seq(start_date, end_date, by = "day")
total_dates <- length(dates)
total_inserted <- 0
total_skipped <- 0

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
    cat(sprintf("  Already have %d records, skipping\n", existing$count[1]))
    total_skipped <- total_skipped + 1
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
    if (length(data) == 0 || is.null(data$times)) {
      # Library was unknown/closed/no data
      return(NULL)
    }

    closed <- data$closed[1]
    if (closed) {
      return(tibble(
        library_id = lib_id,
        date = date_str,
        from_time = NA_character_,
        to_time = NA_character_,
        status_label = "Closed for the whole day"
      ))
    }

    times <- data$times[[1]]
    if (is.null(times) || !all(c("from", "to") %in% names(times))) {
      return(tibble(
        library_id = lib_id,
        date = date_str,
        from_time = NA_character_,
        to_time = NA_character_,
        status_label = "Unknown"
      ))
    }

    times %>%
      mutate(
        library_id = lib_id,
        date = date_str,
        from_time = as.character(from),
        to_time = as.character(to),
        status_label = case_when(
          status == 0 ~ "Temporarily closed",
          status == 1 ~ "Open",
          status == 2 ~ "Self-service",
          TRUE ~ "Unknown"
        )
      ) %>%
      select(library_id, date, from_time, to_time, status_label)

    # Rate limiting: 10 req/s
    Sys.sleep(0.1)
  })

  # Insert into Turso
  if (!is.null(all_schedules) && nrow(all_schedules) > 0) {
    for (i in 1:nrow(all_schedules)) {
      row <- all_schedules[i, ]
      tryCatch({
        turso_execute(
          "INSERT OR IGNORE INTO schedules (library_id, date, from_time, to_time, status_label)
           VALUES (?, ?, ?, ?, ?)",
          list(row$library_id, row$date, row$from_time, row$to_time, row$status_label)
        )
      }, error = function(e) {
        warning(sprintf("Failed to insert record for library %d: %s", row$library_id, e$message))
      })
    }
    cat(sprintf("  ✓ Inserted %d records\n", nrow(all_schedules)))
    total_inserted <- total_inserted + nrow(all_schedules)
  } else {
    cat("  No data available for this date\n")
  }
}

# Summary
cat("\n=== Backfill Complete ===\n")
cat(sprintf("Total dates processed: %d\n", total_dates))
cat(sprintf("Dates skipped (already existed): %d\n", total_skipped))
cat(sprintf("Total records inserted: %d\n", total_inserted))

# Query summary from database
cat("\nDatabase summary:\n")
summary <- turso_query("
  SELECT
    COUNT(DISTINCT date) as total_dates,
    MIN(date) as earliest,
    MAX(date) as latest,
    COUNT(*) as total_records
  FROM schedules
")
print(summary)
