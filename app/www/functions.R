# Load Turso helper functions and the schedule helpers (helsinki_today())
source(here("R", "turso.R"))
source(here("R", "schedules.R"))

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
  # Today (the Finnish date: the opening hours are compared with the Finnish time,
  # and Sys.Date() is the UTC date) and tomorrow, so a page that stays open past
  # midnight can switch to the new day without loading again
  dates <- schedule_dates_to_load()

  with_turso_fallback(
    turso_query_fn = function() {
      turso_query(
        'SELECT library_id, date, from_time as "from", to_time as "to", status_label
         FROM schedules WHERE date >= ? AND date <= ?',
        list(dates[[1]], dates[[2]])
      )
    },
    sqlite_query_fn = function() {
      con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
      on.exit(dbDisconnect(con))
      dbGetQuery(con,
        'SELECT library_id, date, "from", "to", status_label
         FROM schedules WHERE date >= ? AND date <= ?',
        params = list(dates[[1]], dates[[2]])
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
    paste0("<b><a href='", htmltools::htmlEscape(library_url, attribute = TRUE), "' target='_blank' rel='noopener noreferrer'>",
           htmltools::htmlEscape(library_branch_name), "</a></b>"),
    paste0("<b>", htmltools::htmlEscape(library_branch_name), "</b>")
  )

  directions <- sprintf(
    "📍 <a href='https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f' target='_blank' rel='noopener noreferrer' style='color: #C1272D; font-weight: bold;'>Get Directions</a>",
    lat, lon
  )

  extra <- if (!is.null(opening_hours)) {
    paste0("<br>", if_else(!is.na(opening_hours), paste("<b>Hours: </b>", opening_hours), "<b>Hours: </b>NA"))
  } else if (!is.null(distance_display)) {
    paste0("<br><b>Distance: </b>", distance_display)
  } else {
    ""
  }

  paste0(name_html, "<br>", htmltools::htmlEscape(library_address), "<br><b>Status: </b>", open_status, extra, "<br>", directions)
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

# Basemap tile URL templates for a theme: a base layer and a labels layer.
# Esri tile URLs are ordered {z}/{y}/{x} (Carto's were {z}/{x}/{y}).
map_tile_urls <- function(dark = FALSE) {
  theme <- if (dark) "Dark" else "Light"
  url <- function(layer) {
    sprintf(
      "%s/ArcGIS/rest/services/Canvas/World_%s_Gray_%s/MapServer/tile/{z}/{y}/{x}",
      map_tiles_host, theme, layer
    )
  }
  list(base = url("Base"), labels = url("Reference"))
}

# Adds the basemap to a leaflet map: the base layer (which carries the
# attribution) and a labels layer on top. Note: attribution must be addTiles()'s
# own `attribution` argument. addTiles() overwrites options$attribution with it,
# so an attribution passed through tileOptions() is silently dropped.
add_basemap <- function(map, dark = FALSE) {
  urls <- map_tile_urls(dark)
  # Real tiles stop at zoom 16; request nothing above that and scale up
  opts <- leaflet::tileOptions(
    maxZoom = map_max_zoom, maxNativeZoom = map_tile_max_native_zoom
  )
  map <- leaflet::addTiles(
    map,
    urlTemplate = urls$base,
    attribution = map_attribution,
    layerId = "basemap",
    options = opts
  )
  leaflet::addTiles(map, urlTemplate = urls$labels, layerId = "labels", options = opts)
}

# URL of a file in www/ with its modification time appended, so browsers fetch
# a changed file instead of a cached one. Evaluated once when the app starts.
asset <- function(file) {
  path <- file.path("www", file)
  if (!file.exists(path)) return(file)
  paste0(file, "?v=", as.integer(file.mtime(path)))
}

# ---------------------------------------------------------------------------
# Map drawing. Used both for the first render of the map and for the updates
# sent through leafletProxy(), so the two can't drift apart. Each takes a leaflet
# map or a proxy and returns it.
# ---------------------------------------------------------------------------

# Leaflet options; phones get larger touch targets and no accidental zooms
map_options <- function(mobile = FALSE) {
  if (isTRUE(mobile)) {
    leaflet::leafletOptions(
      zoomControl = TRUE,
      dragging = TRUE,
      tap = TRUE,
      tapTolerance = 20,        # larger tap area
      touchZoom = TRUE,
      doubleClickZoom = FALSE,  # prevent accidental double-tap zoom
      scrollWheelZoom = FALSE   # prevent scroll conflicts
    )
  } else {
    leaflet::leafletOptions()
  }
}

add_status_legend <- function(map, colors) {
  leaflet::addLegend(
    map,
    position = "topright",
    layerId = "status_legend",
    colors = vapply(
      c("Open", "Self", "ClosedNow", "ClosedDay", "Unknown"),
      function(name) colors[[name]], character(1), USE.NAMES = FALSE
    ),
    labels = c(
      txt$legend_open, txt$legend_self, txt$legend_closed,
      txt$legend_closed_day, txt$legend_unknown
    ),
    title = txt$legend_title
  )
}

add_library_markers <- function(map, data, colors, mobile = FALSE) {
  leaflet::addCircleMarkers(
    map,
    data = data,
    lng = ~lon,
    lat = ~lat,
    layerId = ~id,
    # fmt: skip
    color = ~ dplyr::case_when(
      open_status == "Open"                              ~ colors$Open,
      open_status == "Self-service"                      ~ colors$Self,
      open_status %in% c("Closed", "Temporarily closed") ~ colors$ClosedNow,
      open_status == "Closed for the whole day"          ~ colors$ClosedDay,
      TRUE                                               ~ colors$Unknown
    ),
    # Non-color status cue (WCAG 1.4.1): closed markers get a dashed, thinner
    # border so status isn't conveyed by color alone.
    # fmt: skip
    weight = ~ dplyr::case_when(
      open_status %in% c("Open", "Self-service") ~ 3,
      TRUE                                        ~ 2
    ),
    # fmt: skip
    dashArray = ~ dplyr::case_when(
      open_status %in% c("Open", "Self-service") ~ NA_character_,
      TRUE                                        ~ "4, 3"
    ),
    radius = if (isTRUE(mobile)) MOBILE_MARKER_RADIUS else DESKTOP_MARKER_RADIUS,
    popup = ~ build_library_popup(
      library_url, library_branch_name, library_address,
      open_status, lat, lon,
      opening_hours = opening_hours
    ),
    label = if (!isTRUE(mobile)) ~library_branch_name else NULL,
    labelOptions = leaflet::labelOptions(
      style = list("font-size" = "14px", "font-weight" = "bold", "color" = "#222")
    ),
    popupOptions = leaflet::popupOptions(
      maxWidth = if (isTRUE(mobile)) MOBILE_POPUP_MAX_WIDTH else DESKTOP_POPUP_MAX_WIDTH,
      minWidth = if (isTRUE(mobile)) MOBILE_POPUP_MIN_WIDTH else DESKTOP_POPUP_MIN_WIDTH,
      autoPan = TRUE,    # auto-pan to show the full popup
      keepInView = TRUE,
      closeButton = TRUE
    )
  )
}

# Zoom to the libraries: a few of them are centred at a fixed zoom, more are
# fitted into view
fit_to_libraries <- function(map, data) {
  if (dplyr::n_distinct(data$id) <= SINGLE_LIBRARY_ZOOM_THRESHOLD) {
    leaflet::setView(
      map,
      lat = mean(data$lat, na.rm = TRUE),
      lng = mean(data$lon, na.rm = TRUE),
      zoom = DEFAULT_ZOOM_LEVEL
    )
  } else {
    leaflet::fitBounds(
      map,
      lng1 = min(data$lon, na.rm = TRUE),
      lat1 = min(data$lat, na.rm = TRUE),
      lng2 = max(data$lon, na.rm = TRUE),
      lat2 = max(data$lat, na.rm = TRUE),
      options = list(maxZoom = map_tile_max_native_zoom)
    )
  }
}

# Everything that depends on the libraries shown and the theme: the basemap
# tiles (replaced by layer id, so a proxy swaps them), the legend and the
# markers. `fit` moves the view; a theme change alone keeps the user's view.
refresh_map <- function(map, data, dark = FALSE, mobile = FALSE, fit = TRUE) {
  colors <- if (dark) dark_colors else light_colors
  map <- map |>
    add_basemap(dark = dark) |>
    leaflet::clearMarkers() |>
    leaflet::clearControls() |>
    add_library_markers(data, colors, mobile) |>
    add_status_legend(colors)
  if (fit) map <- fit_to_libraries(map, data)
  map
}

# The page theme. Light is the default mode. bg/fg are deliberately not set: in
# bslib they define the LIGHT mode, so setting them to the dark brand colours
# (as this app once did) made the page dark in "light" mode and, inverted, light
# in "dark" mode, the opposite of the map. Dark mode is added on top with the
# brand dark background and a lighter red for links.
app_theme <- function() {
  bslib::bs_theme(
    version = 5,
    primary = brand_colours$red,
    base_font = bslib::font_link(
      family = "Gotham",
      href = "https://fonts.cdnfonts.com/css/gotham-6"
    )
  ) |>
    bslib::bs_add_variables(
      "body-bg-dark"          = brand_colours$dark_bg,
      "link-color-dark"       = brand_colours$red_on_dark,
      "link-hover-color-dark" = brand_colours$red_on_dark
    )
}

# The query string of the page address ("?city=Espoo"). A function of its own
# because testServer()'s session has a fixed fake one; tests replace this.
url_search_of <- function(session) session$clientData$url_search

# The open libraries nearest to a point, closest first, with their distance. With
# a service, only libraries offering it count ("the nearest open library with a
# sauna"). The city and library filters are deliberately not applied: what is
# nearest depends on where the user is, not on the city shown on the map.
# A zero-row data frame when nothing qualifies.
nearest_open_libraries <- function(libs, services, lat, lon, n, service = "") {
  open_libs <- libs |> dplyr::filter(open_status %in% c("Open", "Self-service"))

  if (!is.null(service) && nzchar(service)) {
    with_service <- services |>
      dplyr::filter(service_name == service) |>
      dplyr::pull(library_id)
    open_libs <- open_libs |> dplyr::filter(id %in% with_service)
  }

  if (nrow(open_libs) == 0) return(data.frame())

  calculate_distances_to_libraries(user_lat = lat, user_lon = lon, library_data = open_libs) |>
    dplyr::arrange(distance_km) |>
    utils::head(n)
}

# ---------------------------------------------------------------------------
# Opening status, computed from the schedule rows and the clock. Kept apart from
# the data loading so the page can recompute it every minute: a status computed
# once at page load goes stale (a library that opens at 10:00 still read
# "Closed" at 10:45 for anyone who had the page open).
# ---------------------------------------------------------------------------

# The time in Finland as "HH:MM" (strings compare in time order). A function of
# its own so tests can set the clock.
helsinki_time_now <- function() format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")

# Today and tomorrow as "YYYY-MM-DD": the schedules the page loads
schedule_dates_to_load <- function(today = helsinki_today()) {
  as.character(c(today, today + 1))
}

# The schedule rows of one day, with whether each period is on now and the
# status it gives ("Open", "Self-service", "Temporarily closed", "Closed", or
# "Closed for the whole day"). `schedules` has library_id, date, from, to,
# status_label.
todays_schedules <- function(schedules, today, now) {
  schedules %>%
    filter(date == today) %>%
    mutate(
      is_open_now = from <= now & to >= now,
      open_status = case_when(
        status_label == "Closed for the whole day" ~
          "Closed for the whole day",
        is_open_now & status_label == "Open" ~ "Open",
        is_open_now & status_label == "Self-service" ~ "Self-service",
        is_open_now & status_label == "Temporarily closed" ~
          "Temporarily closed",
        TRUE ~ "Closed"
      )
    )
}

# The libraries with their status now: one row per library, with the period that
# is on now (or else the one that ends last) deciding the status. A library with
# no schedule rows for the day gets NA (shown as "no status data").
compute_library_statuses <- function(libraries, schedules, today, now) {
  map_display <- todays_schedules(schedules, today, now) %>%
    group_by(library_id) %>%
    arrange(desc(is_open_now), desc(to)) %>%
    slice(1) %>%
    ungroup() %>%
    mutate(
      opening_hours = if_else(
        is_open_now,
        paste0(from, " - ", to),
        NA_character_
      )
    )

  libraries %>%
    left_join(map_display, by = join_by(id == library_id))
}

# Milliseconds until a little after the next full minute: the statuses can only
# change on the minute, so the page checks then and not at some random offset
ms_to_next_minute <- function(now = Sys.time()) {
  seconds <- as.numeric(format(now, "%OS3"))     # seconds into the minute, with milliseconds
  max(1000, round((60 - seconds) * 1000) + 500)
}

