library(dplyr)
library(here)
library(httr)
library(jsonlite)
library(purrr)
library(RSQLite)
library(stringr)
library(tidyr)

# Load Turso helper functions
source(here("R/turso.R"))

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
      # Fixing Seinäjoki main library coordinates, because there are two
      # buildings with different opening hours. Also adding coordinates for
      # the libraries that are missing them, and fixing broken URLs.
      left_join(
        coord_overrides %>% select(id, lat_override = lat, lon_override = lon),
        by = "id"
      ) %>%
      left_join(
        url_overrides %>% select(id, url_override = url),
        by = "id"
      ) %>%
      mutate(
        lat = coalesce(lat_override, lat),
        lon = coalesce(lon_override, lon),
        library_url = coalesce(url_override, library_url),
        library_address = paste(
          street_address,
          zip_code,
          city_name,
          sep = ", "
        )
      ) %>%
      select(-lat_override, -lon_override, -url_override) %>%
      # Libraries with no separate address of their own (reading rooms etc.)
      filter(
        !is.na(lat) & !is.na(lon) & !id %in% exclusions$id
      ) %>%
      select(-c(street_address, zip_code))

    return(list(libraries = libraries, raw_data = data))
  } else {
    stop("Failed to fetch libraries")
  }
}

# Fetch schedules from API
fetch_schedules_from_api <- function(libraries) {
  api_url <- "https://api.kirjastot.fi/v4/schedules"
  today <- format(Sys.Date(), tz = "Europe/Helsinki")

  schedules <- map_dfr(libraries$id, function(library_id) {
    response <- GET(api_url, query = list(library = library_id, date = today))

    if (status_code(response) == 200) {
      data <- fromJSON(
        content(response, "text", encoding = "UTF-8"),
        flatten = TRUE
      )$items

      if (length(data) == 0 || is.null(data$times)) {
        return(
          # fmt: skip
          tibble(
              library_id,
              date          = today,
              from_time     = NA_character_,
              to_time       = NA_character_,
              status_label  = "Unknown"
          )
        )
      }

      closed <- data$closed[1]

      if (closed) {
        return(
          # fmt: skip
          tibble(
              library_id,
              date          = today,
              from_time     = NA_character_,
              to_time       = NA_character_,
              status_label  = "Closed for the whole day"
          )
        )
      }

      times <- data$times[[1]]

      if (
        is.null(times) ||
          !all(c("from", "to") %in% names(times))
      ) {
        return(
          # fmt: skip
          tibble(
            library_id,
            date         = today,
            from_time    = NA_character_,
            to_time      = NA_character_,
            status_label = "Unknown"
          )
        )
      }

      times %>%
        # fmt: skip
        mutate(
          library_id   = library_id,
          date         = today,
          from_time    = as.character(from),
          to_time      = as.character(to),
          status_label = case_when(
            status == 0 ~ "Temporarily closed",
            status == 1 ~ "Open",
            status == 2 ~ "Self-service",
            TRUE ~ "Unknown"
          )
        ) %>%
        select(library_id, date, from_time, to_time, status_label)
    } else {
      # fmt: skip
      tibble(
        library_id,
        date         = today,
        from_time    = NA_character_,
        to_time      = NA_character_,
        status_label = "Unknown"
      )
    }
  })

  return(schedules)
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
    warning("Turso write failed - SQLite backup maintained")
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

  schedules <- fetch_schedules_from_api(libraries)
  cat(sprintf("Fetched %d schedule records\n", nrow(schedules)))

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

  # Write to Turso (append mode - preserves historical data)
  turso_success <- tryCatch({
    cat("Writing schedules to Turso...\n")

    # Use INSERT OR IGNORE to skip duplicates (UNIQUE constraint handles this)
    schedule_statements <- purrr::pmap(schedules, function(library_id, date, from_time,
                                                            to_time, status_label, ...) {
      list(
        sql = "INSERT OR IGNORE INTO schedules (library_id, date, from_time, to_time, status_label)
               VALUES (?, ?, ?, ?, ?)",
        params = list(library_id, date, from_time, to_time, status_label)
      )
    })
    turso_execute_batch(schedule_statements)
    cat(sprintf("✓ Wrote %d schedule records to Turso\n", nrow(schedules)))
    TRUE
  }, error = function(e) {
    warning("Failed to write schedules to Turso: ", conditionMessage(e))
    FALSE
  })

  # Always write to SQLite as backup (overwrite - only today's data)
  cat("Writing schedules to SQLite backup...\n")
  con <- dbConnect(SQLite(), dbname = here("app/libraries.sqlite"))
  # Rename columns back to original schema for SQLite compatibility
  schedules_sqlite <- schedules %>%
    rename(from = from_time, to = to_time)
  dbWriteTable(con, "schedules", schedules_sqlite, overwrite = TRUE)
  dbDisconnect(con)
  cat("✓ Wrote schedules to SQLite\n")

  if (!turso_success) {
    warning("Turso write failed - SQLite backup maintained")
  }
}

cat("\n=== Data fetch complete ===\n")
