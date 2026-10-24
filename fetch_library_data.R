library(dplyr)
library(here)
library(httr)
library(jsonlite)
library(purrr)
library(RSQLite)
library(stringr)
library(tidyr)

# Load Turso helper functions and the schedule fetching/parsing
source(here("R/turso.R"))
source(here("R/schedules.R"))
source(here("R/coordinates.R"))

# Determine update type from environment variable (default: schedules only)
update_type <- Sys.getenv("UPDATE_TYPE", unset = "schedules")
cat(sprintf("Update mode: %s\n", update_type))

# Fetch libraries from API
fetch_libraries_from_api <- function() {
  api_url <- "https://api.kirjastot.fi/v4/library"
  response <- GET(
    api_url,
    query = list(
      type = "municipal",
      limit = 1000,
      with = "primaryContactInfo",
      with = "services"
    )
  )

  if (status_code(response) == 200) {
    data <- fromJSON(
      content(response, "text", encoding = "UTF-8"),
      flatten = TRUE
    )$items
    # Note: Services extracted separately to library_services table (no join/split)

    # Manual data-quality overrides, externalized to data/ so they can grow
    # without bloating this script. See data/library_*.csv for the values.
    coord_overrides <- read.csv(here("data", "library_coordinate_overrides.csv"), stringsAsFactors = FALSE)
    # The last good coordinates of every library: used when the API has none, or
    # some that can't be in Finland (it once had 0, 0). See R/coordinates.R.
    coord_snapshot_path <- here("data", "library_coordinates.csv")
    coord_snapshot <- read_coordinate_snapshot(coord_snapshot_path)
    url_overrides <- read.csv(here("data", "library_url_overrides.csv"), stringsAsFactors = FALSE)
    exclusions <- read.csv(here("data", "library_exclusions.csv"), stringsAsFactors = FALSE)

    libraries <- data %>%
      # fmt: skip
      transmute(
        id,
        library_branch_name = name,
        lat                 = coordinates.lat,
        lon                 = coordinates.lon,
        city_name           = address.city,
        zip_code            = address.zipcode,
        street_address      = address.street,
        library_url         = primaryContactInfo.homepage.url,
        library_phone       = primaryContactInfo.phone.number,
        library_email       = primaryContactInfo.email.email
      ) %>%
      # Fixing broken URLs (the coordinates are resolved below)
      left_join(
        url_overrides %>% select(id, url_override = url),
        by = "id"
      ) %>%
      mutate(
        library_url = coalesce(url_override, library_url),
        library_address = paste(
          street_address,
          zip_code,
          city_name,
          sep = ", "
        )
      ) %>%
      select(-url_override, -street_address, -zip_code) %>%
      # Libraries with no separate address of their own (reading rooms etc.)
      filter(!id %in% exclusions$id)

    # Coordinates: the manual overrides (e.g. the Seinäjoki main library, which
    # shares an address with another building, and libraries the API has none
    # for), else the API's if they can be in Finland, else the last good ones
    coordinates <- resolve_coordinates(libraries, coord_overrides, coord_snapshot)
    libraries$lat <- coordinates$lat
    libraries$lon <- coordinates$lon

    # Say what had to be rescued, and keep the snapshot in step
    from_snapshot <- coordinates$id[coordinates$source == "snapshot"]
    if (length(from_snapshot) > 0) {
      cat(sprintf(
        "The API's coordinates were missing or outside Finland for %d libraries, the last good ones are used: %s\n",
        length(from_snapshot),
        paste(sprintf("%s (%s)", from_snapshot, libraries$library_branch_name[match(from_snapshot, libraries$id)]), collapse = ", ")
      ))
    }
    without <- coordinates$id[coordinates$source == "none"]
    if (length(without) > 0) {
      warning(sprintf(
        "%d libraries have no usable coordinates (API and snapshot) and are left out: %s",
        length(without),
        paste(sprintf("%s (%s)", without, libraries$library_branch_name[match(without, libraries$id)]), collapse = ", ")
      ))
    }
    if (write_coordinate_snapshot(build_coordinate_snapshot(coordinates, libraries), coord_snapshot_path)) {
      cat("Updated data/library_coordinates.csv\n")
    }

    libraries <- libraries %>% filter(!is.na(lat) & !is.na(lon))

    return(list(libraries = libraries, raw_data = data))
  } else {
    stop("Failed to fetch libraries")
  }
}

# =============================================================================
# MODE 1: UPDATE LIBRARIES (Weekly - Sunday)
# =============================================================================

if (update_type %in% c("libraries", "both")) {
  cat("\n=== Fetching library metadata ===\n")
  result <- fetch_libraries_from_api()
  libraries <- result$libraries
  raw_data <- result$raw_data
  cat(sprintf("Fetched %d libraries\n", nrow(libraries)))

  # Extract library services directly from API data (no join/split needed!)
  cat("Extracting library services...\n")

  # Build list of all library-service pairs
  all_services <- list()
  for (i in 1:nrow(raw_data)) {
    lib_id <- raw_data$id[i]
    svcs <- raw_data$services[[i]]
    if (is.data.frame(svcs) && nrow(svcs) > 0 && "standardName" %in% names(svcs)) {
      for (j in 1:nrow(svcs)) {
        if (!is.na(svcs$standardName[j]) && svcs$standardName[j] != "") {
          all_services[[length(all_services) + 1]] <- data.frame(
            library_id = lib_id,
            service_name = svcs$standardName[j],
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }
  library_services <- dplyr::bind_rows(all_services) %>%
    dplyr::distinct() %>%
    # Only keep services for libraries that passed filtering
    dplyr::filter(library_id %in% libraries$id)
  cat(sprintf("Extracted %d library-service combinations (%d unique services)\n",
              nrow(library_services), n_distinct(library_services$service_name)))

  # Write to Turso
  turso_success <- tryCatch({
    cat("Writing libraries to Turso...\n")

    # Delete library_services first (FK constraint requires this order)
    turso_execute("DELETE FROM library_services")

    # Delete all existing libraries (replace mode)
    turso_execute("DELETE FROM libraries")

    # Insert each library (library_services now in separate table)
    library_statements <- purrr::pmap(libraries, function(id, library_branch_name, lat, lon,
                                                           city_name, library_url, library_phone,
                                                           library_email, library_address, ...) {
      list(
        sql = "INSERT INTO libraries (id, library_branch_name, lat, lon, city_name,
                                      library_url, library_phone, library_email,
                                      library_address)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params = list(
          id, library_branch_name, lat, lon, city_name,
          library_url, library_phone, library_email, library_address
        )
      )
    })
    turso_execute_batch(library_statements)
    cat(sprintf("✓ Wrote %d libraries to Turso\n", nrow(libraries)))

    # Write services to library_services table
    cat("Writing library services to Turso...\n")
    service_statements <- purrr::pmap(library_services, function(library_id, service_name, ...) {
      list(
        sql = "INSERT INTO library_services (library_id, service_name) VALUES (?, ?)",
        params = list(library_id, service_name)
      )
    })
    turso_execute_batch(service_statements)
    cat(sprintf("✓ Wrote %d service records to Turso\n", nrow(library_services)))

    TRUE
  }, error = function(e) {
    warning("Failed to write libraries to Turso: ", conditionMessage(e))
    FALSE
  })

  # Always write to SQLite as backup
  cat("Writing libraries and services to SQLite backup...\n")
  con <- dbConnect(SQLite(), dbname = here("app/libraries.sqlite"))
  dbWriteTable(con, "libraries", libraries, overwrite = TRUE)
  dbWriteTable(con, "library_services", library_services, overwrite = TRUE)
  dbDisconnect(con)
  cat(sprintf("✓ Wrote %d libraries and %d services to SQLite\n",
              nrow(libraries), nrow(library_services)))

  if (!turso_success) {
    stop("Turso write failed - SQLite backup was written, but production database was NOT updated. Investigate before the next scheduled run.")
  }
}

# =============================================================================
# MODE 2: UPDATE SCHEDULES (Daily)
# =============================================================================

if (update_type %in% c("schedules", "both")) {
  cat("\n=== Fetching schedule data ===\n")

  # Get libraries from Turso or SQLite
  libraries <- tryCatch({
    turso_query("SELECT id FROM libraries")
  }, error = function(e) {
    warning("Failed to read libraries from Turso, using SQLite")
    con <- dbConnect(SQLite(), dbname = here("app/libraries.sqlite"), read_only = TRUE)
    libs <- dbReadTable(con, "libraries") %>% select(id)
    dbDisconnect(con)
    libs
  })

  # A window of days, not only today: GitHub starts this job hours late, and
  # with the days ahead already stored the app has today's hours at midnight
  dates <- schedule_window()
  cat(sprintf("Fetching schedules for %s to %s\n", min(dates), max(dates)))
  schedules <- fetch_schedules_from_api(libraries, dates)
  cat(sprintf("Fetched %d schedule records\n", nrow(schedules)))

  # If the API failed for many libraries the data is not worth storing: stop
  # before replacing good data with "Unknown" rows
  unknown_share <- mean(schedules$status_label == "Unknown")
  if (unknown_share > 0.5) {
    stop(sprintf(
      "%.0f%% of the fetched schedule rows are Unknown - the Kirkanta API looks broken. Nothing was written.",
      100 * unknown_share
    ))
  }

  # Orphaned data detection
  orphaned <- schedules %>%
    anti_join(libraries, by = c("library_id" = "id"))

  if (nrow(orphaned) > 0) {
    warning(sprintf(
      "Found %d orphaned schedule records for unknown libraries: %s",
      nrow(orphaned),
      paste(unique(orphaned$library_id), collapse = ", ")
    ))
  }

  # Write to Turso. Past days are kept (history); the window from today on is
  # replaced, so changed opening hours are picked up and a second run on the same
  # day doesn't pile up duplicate rows (the UNIQUE constraint can't catch rows
  # with NULL times). Replaced a group of libraries at a time, each group in one
  # transaction (see schedule_write_groups()): deleting the whole window first and
  # inserting afterwards left the libraries at the end of the list without a
  # schedule for the minutes the writing took.
  turso_success <- tryCatch({
    cat("Writing schedules to Turso...\n")

    groups <- schedule_write_groups(schedules, first_date = min(dates))
    cat(sprintf("%d groups of libraries, each written in one transaction\n", length(groups)))
    for (group in groups) turso_execute_atomic(group)
    cat(sprintf("✓ Wrote %d schedule records to Turso\n", nrow(schedules)))
    TRUE
  }, error = function(e) {
    warning("Failed to write schedules to Turso: ", conditionMessage(e))
    FALSE
  })

  # Always write to SQLite as backup (overwrite - the whole window, which is what
  # the app's fallback needs to show statuses for the next days too)
  cat("Writing schedules to SQLite backup...\n")
  con <- dbConnect(SQLite(), dbname = here("app/libraries.sqlite"))
  # Rename columns back to original schema for SQLite compatibility
  schedules_sqlite <- schedules %>%
    rename(from = from_time, to = to_time)
  dbWriteTable(con, "schedules", schedules_sqlite, overwrite = TRUE)
  dbDisconnect(con)
  cat("✓ Wrote schedules to SQLite\n")

  if (!turso_success) {
    stop("Turso write failed - SQLite backup was written, but production database was NOT updated. Investigate before the next scheduled run.")
  }
}

cat("\n=== Data fetch complete ===\n")
