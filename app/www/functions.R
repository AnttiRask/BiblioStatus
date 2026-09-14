# Load Turso helper functions
source(here("R", "turso.R"))

# Load Turso credentials
TURSO_DATABASE_URL <- Sys.getenv("TURSO_DATABASE_URL")
TURSO_AUTH_TOKEN <- Sys.getenv("TURSO_AUTH_TOKEN")
if (TURSO_DATABASE_URL == "" && file.exists("secret.R")) {
  source("secret.R")
}

# Load Carto API key (required by CartoDB basemap tiles)
CARTO_API_KEY <- Sys.getenv("CARTO_API_KEY")
if (CARTO_API_KEY == "" && file.exists("secret.R")) {
  source("secret.R")
}

# SQLite fallback path (auto-detect for shinyapps.io vs Docker/local)
db_path <- if (file.exists(here("libraries.sqlite"))) {
  here("libraries.sqlite")
} else {
  here("app", "libraries.sqlite")
}

# Run a Turso query, falling back to the SQLite backup if it errors.
with_turso_fallback <- function(turso_query_fn, sqlite_query_fn, context) {
  tryCatch({
    turso_query_fn()
  }, error = function(e) {
    warning(sprintf("Turso failed (%s), using SQLite: %s", context, e$message))
    sqlite_query_fn()
  })
}

# Function to fetch libraries (Turso primary, SQLite fallback)
fetch_libraries <- function() {
  with_turso_fallback(
    turso_query_fn = function() turso_query("SELECT * FROM libraries"),
    sqlite_query_fn = function() {
      con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
      on.exit(dbDisconnect(con))
      dbReadTable(con, "libraries")
    },
    context = "libraries"
  )
}

# Function to fetch schedules (Turso primary, SQLite fallback)
fetch_schedules <- function() {
  today <- format(Sys.Date(), "%Y-%m-%d")

  with_turso_fallback(
    turso_query_fn = function() {
      turso_query(
        'SELECT library_id, date, from_time as "from", to_time as "to", status_label
         FROM schedules WHERE date = ?',
        list(today)
      )
    },
    sqlite_query_fn = function() {
      con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
      on.exit(dbDisconnect(con))
      dbGetQuery(con,
        'SELECT library_id, date, "from", "to", status_label
         FROM schedules WHERE date = ?',
        params = list(today)
      )
    },
    context = "schedules"
  )
}

# Function to fetch library services (Turso primary, SQLite fallback)
fetch_library_services <- function() {
  with_turso_fallback(
    turso_query_fn = function() {
      turso_query("SELECT library_id, service_name FROM library_services ORDER BY library_id, service_name")
    },
    sqlite_query_fn = function() {
      con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
      on.exit(dbDisconnect(con))
      dbGetQuery(con, "
        SELECT library_id, service_name
        FROM library_services
        ORDER BY library_id, service_name
      ")
    },
    context = "services"
  )
}

# Calculate distance between two points using Haversine formula (km)
calculate_distance <- function(lat1, lon1, lat2, lon2) {
  R <- 6371  # Earth's radius in km

  lat1_rad <- lat1 * pi / 180
  lat2_rad <- lat2 * pi / 180
  delta_lat <- (lat2 - lat1) * pi / 180
  delta_lon <- (lon2 - lon1) * pi / 180

  a <- sin(delta_lat / 2)^2 +
       cos(lat1_rad) * cos(lat2_rad) *
       sin(delta_lon / 2)^2
  c <- 2 * atan2(sqrt(a), sqrt(1 - a))

  R * c
}

# Vectorized distance calculation for multiple libraries
calculate_distances_to_libraries <- function(user_lat, user_lon, library_data) {
  library_data %>%
    mutate(
      distance_km = mapply(
        calculate_distance,
        lat1 = user_lat,
        lon1 = user_lon,
        lat2 = lat,
        lon2 = lon
      ),
      distance_display = sprintf("%.1f km", distance_km)
    )
}

# Build the HTML for a library's map popup. Vector-safe (used inside a `~`
# formula over a data frame in addCircleMarkers). Pass opening_hours for the
# main map popup, or distance_display for the "nearest libraries" popup.
build_library_popup <- function(library_url, library_branch_name, library_address,
                                 open_status, lat, lon,
                                 opening_hours = NULL, distance_display = NULL) {
  name_html <- if_else(
    !is.na(library_url),
    paste0("<b><a href='", library_url, "' target='_blank'>", library_branch_name, "</a></b>"),
    paste0("<b>", library_branch_name, "</b>")
  )

  directions <- sprintf(
    "📍 <a href='https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f' target='_blank' style='color: #C1272D; font-weight: bold;'>Get Directions</a>",
    lat, lon
  )

  extra <- if (!is.null(opening_hours)) {
    paste0("<br>", if_else(!is.na(opening_hours), paste("<b>Hours: </b>", opening_hours), "<b>Hours: </b>NA"))
  } else if (!is.null(distance_display)) {
    paste0("<br><b>Distance: </b>", distance_display)
  } else {
    ""
  }

  paste0(name_html, "<br>", library_address, "<br><b>Status: </b>", open_status, extra, "<br>", directions)
}

# Format all schedule periods for a library
# Highlights current period to emphasize "right now" status
format_schedule_periods <- function(library_id, all_schedules, now_time) {
  periods <- all_schedules %>%
    filter(library_id == !!library_id) %>%
    arrange(from) %>%
    mutate(
      is_current = from <= now_time & to >= now_time,
      period_text = paste0(
        from, "-", to, " (", status_label, ")",
        if_else(is_current, " ← now", "")
      )
    )

  if (nrow(periods) == 0) {
    return("No schedule information available")
  }

  # Return as HTML list (current period bolded)
  period_items <- periods %>%
    mutate(html = if_else(
      is_current,
      paste0("<li><strong>", period_text, "</strong></li>"),
      paste0("<li>", period_text, "</li>")
    )) %>%
    pull(html) %>%
    paste(collapse = "\n")

  paste0("<ul style='margin: 0; padding-left: 20px;'>\n", period_items, "\n</ul>")
}
