#!/usr/bin/env Rscript

# Check if all library URLs in the database are working
library(dplyr)
library(httr)
library(RSQLite)
library(here)

# Connect to database
con <- dbConnect(
  SQLite(),
  dbname = here("app/libraries.sqlite")
)

# Get all libraries with URLs
libraries <- dbGetQuery(
  con,
  "SELECT id, library_branch_name, library_url, city_name
   FROM libraries
   WHERE library_url IS NOT NULL AND library_url != ''"
) %>%
  as_tibble()

dbDisconnect(con)

cat(sprintf("Checking %d library URLs...\n\n", nrow(libraries)))

# Function to check URL
check_url <- function(url, id, name) {
  # Clean up URL (remove leading/trailing spaces)
  url <- trimws(url)

  tryCatch({
    response <- GET(url, timeout(10))
    status <- status_code(response)

    if (status >= 200 && status < 400) {
      cat(sprintf("✓ [%d] %s - %s (HTTP %d)\n", id, name, url, status))
      return(list(id = id, name = name, url = url, status = status, working = TRUE))
    } else {
      cat(sprintf("✗ [%d] %s - %s (HTTP %d)\n", id, name, url, status))
      return(list(id = id, name = name, url = url, status = status, working = FALSE))
    }
  }, error = function(e) {
    cat(sprintf("✗ [%d] %s - %s (ERROR: %s)\n", id, name, url, e$message))
    return(list(id = id, name = name, url = url, status = NA, working = FALSE, error = e$message))
  })
}

# Check all URLs
results <- purrr::map(
  seq_len(nrow(libraries)),
  ~ {
    lib <- libraries[.x, ]
    check_url(lib$library_url, lib$id, lib$library_branch_name)
  }
)

# Summarize results
results_df <- bind_rows(results)
broken_urls <- results_df %>% filter(!working)

cat("\n=== SUMMARY ===\n")
cat(sprintf("Total URLs checked: %d\n", nrow(results_df)))
cat(sprintf("Working: %d\n", sum(results_df$working)))
cat(sprintf("Broken: %d\n", nrow(broken_urls)))

if (nrow(broken_urls) > 0) {
  cat("\n=== BROKEN URLS ===\n")
  for (i in seq_len(nrow(broken_urls))) {
    row <- broken_urls[i, ]
    cat(sprintf(
      "%d. [ID: %d] %s\n   URL: %s\n   Status: %s\n\n",
      i,
      row$id,
      row$name,
      row$url,
      ifelse(is.na(row$status), paste("ERROR -", row$error), paste("HTTP", row$status))
    ))
  }

  # Exit with error code so GitHub Actions can send email
  quit(status = 1, save = "no")
}
