# Connect to SQLite (auto-detect path for shinyapps.io vs Docker/local)
db_path <- if (file.exists(here("libraries.sqlite"))) {
  here("libraries.sqlite")
} else {
  here("app", "libraries.sqlite")
}

# Function to fetch libraries from SQLite
fetch_libraries <- function() {
  # fmt: skip
  con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
  libraries <- dbReadTable(con, "libraries")
  dbDisconnect(con)

  return(libraries)
}

# Function to fetch schedules from SQLite and determine the current open status
fetch_schedules <- function() {
  # fmt: skip
  con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
  schedules <- dbReadTable(con, "schedules")
  dbDisconnect(con)

  return(schedules)
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
