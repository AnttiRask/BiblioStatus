# Map: marker rendering, marker clicks, Find Nearest.
# Evaluated inside server() (see server_parts in server.R), so it shares the
# session's reactive state, input, output and session. State: selection, library_data, nearest_libraries, user_location, selected_library.

# The libraries the map shows: the ones matching the selection
libraries_on_map <- reactive({
  libs <- library_data()
  req(libs)
  svcs <- library_services_data()
  if (is.null(svcs)) svcs <- data.frame(library_id = numeric(), service_name = character())
  filter_libraries(libs, svcs, selection())
})

# The map is rendered ONCE, with the libraries and the theme of that moment.
# Later changes (the filters, dark mode) are sent as small updates through
# leafletProxy(): the map keeps its tiles and, when only the theme changes, its
# view, instead of being rebuilt (which re-requested every tile and reset the
# zoom). Rendering waits for the startup city and for the device type (is_mobile
# is reported by the browser a moment after the page loads); neither changes
# again, so the render doesn't run twice. Everything else is read with
# isolate(), which is what keeps filter changes from re-rendering the map.
#
# The ids of the libraries last fitted into view: the view only moves when the
# set of libraries changes.
fitted <- new.env()

output$map <- renderLeaflet({
  req(startup_city_set())
  mobile <- input$is_mobile
  req(!is.null(mobile))

  data <- isolate(libraries_on_map())
  req(nrow(data) > 0)
  fitted$ids <- sort(data$id)

  leaflet(data, options = map_options(mobile)) |>
    refresh_map(data, dark = isolate(is_dark()), mobile = isTRUE(mobile), fit = TRUE)
})

# Filters or the theme changed: update the existing map. A proxy message sent
# before the browser has built the map is dropped, which is harmless: the
# render above already used the current selection. ignoreInit skips the
# start-up run (the render draws the first map).
observeEvent(
  list(libraries_on_map(), is_dark()),
  {
    req(startup_city_set())
    data <- libraries_on_map()
    req(nrow(data) > 0)

    ids <- sort(data$id)
    fit <- !identical(ids, fitted$ids)   # a theme change alone doesn't move the view
    fitted$ids <- ids

    refresh_map(
      leafletProxy("map"), data,
      dark = is_dark(), mobile = isTRUE(input$is_mobile), fit = fit
    )
  },
  ignoreInit = TRUE
)

# The first time the browser reports the map's bounds the map exists: remove the
# loading text and show it
observeEvent(input$map_bounds, {
  hide("loading-spinner")
  runjs("document.getElementById('map').style.visibility = 'visible';")
}, once = TRUE)

# Click marker to update sidebar
observeEvent(input$map_marker_click, {
  click_id <- input$map_marker_click$id

  # Ignore clicks on user location marker
  if (is.null(click_id) || click_id == "user_location") {
    return()
  }

  data <- isolate(library_data())
  selected <- data %>% filter(id == click_id)
  selected_library(selected)
})

# Reset selected library on map click (not marker)
observeEvent(input$map_click, {
  selected_library(NULL)
})

# Handle "Find Nearest" button click
observeEvent(input$find_nearest, {
  nearest_libraries(NULL)
  session$sendCustomMessage('requestGeolocation', list())
})

# Handle successful geolocation
observeEvent(input$user_location, {
  req(input$user_location)
  req(library_data())

  user_loc <- input$user_location
  user_location(user_loc)

  # Filter to only open/self-service libraries
  open_libs <- library_data() %>%
    filter(open_status %in% c("Open", "Self-service"))

  if (nrow(open_libs) == 0) {
    nearest_libraries(data.frame())
    showNotification(txt$no_open_nearby, type = "warning")
    return()
  }

  # Calculate distances and get top 5
  libs_with_distance <- calculate_distances_to_libraries(
    user_lat = user_loc$lat,
    user_lon = user_loc$lon,
    library_data = open_libs
  )

  nearest <- libs_with_distance %>%
    arrange(distance_km) %>%
    head(if (isTRUE(input$is_mobile)) MOBILE_NEAREST_COUNT else DESKTOP_NEAREST_COUNT)

  nearest_libraries(nearest)

  # Update map to show nearest libraries
  update_map_for_nearest(nearest, user_loc)
})

# Handle geolocation errors
observeEvent(input$geolocation_error, {
  req(input$geolocation_error)
  showNotification(input$geolocation_error, type = "error", duration = 5)
})

# Map update function for nearest libraries
update_map_for_nearest <- function(nearest_libs, user_loc) {
  req(nrow(nearest_libs) > 0)

  chosen_colors <- if (is_dark()) dark_colors else light_colors

  # Calculate map bounds
  all_lats <- c(user_loc$lat, nearest_libs$lat)
  all_lons <- c(user_loc$lon, nearest_libs$lon)

  leafletProxy("map") %>%
    clearMarkers() %>%
    # User location marker (red "You Are Here" marker)
    addCircleMarkers(
      lng = user_loc$lon,
      lat = user_loc$lat,
      layerId = "user_location",
      radius = USER_LOCATION_MARKER_RADIUS,
      color = "#FF0000",
      fillColor = "#FF0000",
      fillOpacity = 0.8,
      weight = 2,
      popup = "<b>Your Location</b>"
    ) %>%
    # Nearest library markers
    addCircleMarkers(
      data = nearest_libs,
      lng = ~lon,
      lat = ~lat,
      layerId = ~id,
      color = ~ case_when(
        open_status == "Open"                              ~ chosen_colors$Open,
        open_status == "Self-service"                      ~ chosen_colors$Self,
        open_status %in% c("Closed", "Temporarily closed") ~ chosen_colors$ClosedNow,
        open_status == "Closed for the whole day"          ~ chosen_colors$ClosedDay,
        TRUE                                               ~ chosen_colors$Unknown
      ),
      radius = if (isTRUE(input$is_mobile)) MOBILE_NEAREST_MARKER_RADIUS else DESKTOP_NEAREST_MARKER_RADIUS,
      popup = ~ build_library_popup(
        library_url, library_branch_name, library_address,
        open_status, lat, lon,
        distance_display = distance_display
      )
    ) %>%
    fitBounds(
      lng1 = min(all_lons) - 0.01,
      lat1 = min(all_lats) - 0.01,
      lng2 = max(all_lons) + 0.01,
      lat2 = max(all_lats) + 0.01,
      options = list(maxZoom = map_tile_max_native_zoom)
    )
}
