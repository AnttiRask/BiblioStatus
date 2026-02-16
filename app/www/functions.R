# Load Turso helper functions
source("www/turso.R")

# Load Turso credentials
TURSO_DATABASE_URL <- Sys.getenv("TURSO_DATABASE_URL")
TURSO_AUTH_TOKEN <- Sys.getenv("TURSO_AUTH_TOKEN")
if (TURSO_DATABASE_URL == "" && file.exists("secret.R")) {
  source("secret.R")
}

# SQLite fallback path (auto-detect for shinyapps.io vs Docker/local)
db_path <- if (file.exists(here("libraries.sqlite"))) {
  here("libraries.sqlite")
} else {
  here("app", "libraries.sqlite")
}

# Function to fetch libraries (Turso primary, SQLite fallback)
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

# Function to fetch schedules (Turso primary, SQLite fallback)
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
    'SELECT library_id, date, "from", "to", status_label
     FROM schedules WHERE date = ?',
    params = list(today)
  )
  dbDisconnect(con)
  return(data)
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
