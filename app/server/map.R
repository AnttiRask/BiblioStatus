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

# Render the map when the selection, dark mode, the data or the startup city
# change. The startup city is part of the trigger so the first map is drawn
# even when it doesn't change the selection (e.g. after a reconnect).
observeEvent(
  list(libraries_on_map(), is_dark(), startup_city_set()),
  {
    req(startup_city_set())  # wait until startup city is determined
    data <- libraries_on_map()
    req(nrow(data) > 0)

    output$map <- renderLeaflet({
      chosen_colors <- if (is_dark()) dark_colors else light_colors

      # Mobile-optimized leaflet options
      leaflet_options <- if (isTRUE(input$is_mobile)) {
        leafletOptions(
          zoomControl = TRUE,
          dragging = TRUE,
          tap = TRUE,
          tapTolerance = 20,  # Larger tap area for mobile
          touchZoom = TRUE,
          doubleClickZoom = FALSE,  # Prevent accidental double-tap zoom
          scrollWheelZoom = FALSE   # Prevent scroll conflicts on mobile
        )
      } else {
        leafletOptions()
      }

      map <- leaflet(data, options = leaflet_options) %>%
        add_basemap(dark = is_dark()) %>%
        addCircleMarkers(
          lng = ~lon,
          lat = ~lat,
          layerId = ~id,
          # fmt: skip
          color = ~ case_when(
            open_status == "Open"                              ~ chosen_colors$Open,
            open_status == "Self-service"                      ~ chosen_colors$Self,
            open_status %in% c("Closed", "Temporarily closed") ~ chosen_colors$ClosedNow,
            open_status == "Closed for the whole day"          ~ chosen_colors$ClosedDay,
            TRUE                                               ~ chosen_colors$Unknown
          ),
          # Non-color status cue (WCAG 1.4.1): closed markers get a dashed,
          # thinner border so status isn't conveyed by color alone.
          # fmt: skip
          weight = ~ case_when(
            open_status %in% c("Open", "Self-service") ~ 3,
            TRUE                                        ~ 2
          ),
          # fmt: skip
          dashArray = ~ case_when(
            open_status %in% c("Open", "Self-service") ~ NA_character_,
            TRUE                                        ~ "4, 3"
          ),
          radius = if (isTRUE(input$is_mobile)) MOBILE_MARKER_RADIUS else DESKTOP_MARKER_RADIUS,
          popup = ~ build_library_popup(
            library_url, library_branch_name, library_address,
            open_status, lat, lon,
            opening_hours = opening_hours
          ),
          label = if (!isTRUE(input$is_mobile)) {
            ~library_branch_name
          } else {
            NULL
          },
          labelOptions = labelOptions(
            style = list(
              "font-size" = "14px",
              "font-weight" = "bold",
              "color" = "#222"
            )
          ),
          popupOptions = popupOptions(
            maxWidth = if (isTRUE(input$is_mobile)) MOBILE_POPUP_MAX_WIDTH else DESKTOP_POPUP_MAX_WIDTH,
            minWidth = if (isTRUE(input$is_mobile)) MOBILE_POPUP_MIN_WIDTH else DESKTOP_POPUP_MIN_WIDTH,
            autoPan = TRUE,  # Auto-pan to show full popup
            keepInView = TRUE,  # Keep popup in view
            closeButton = TRUE
          )
        ) %>%
        addLegend(
          position = "topright",
          colors = map_chr(
            c("Open", "Self", "ClosedNow", "ClosedDay"),
            ~ chosen_colors[[.x]]
          ),
          labels = c(
            txt$legend_open,
            txt$legend_self,
            txt$legend_closed,
            txt$legend_closed_day
          ),
          title = txt$legend_title
        )

      # Zoom logic
      if (data %>% distinct(id) %>% nrow() <= SINGLE_LIBRARY_ZOOM_THRESHOLD) {
        map <- map %>%
          setView(
            lat = mean(data$lat, na.rm = TRUE),
            lng = mean(data$lon, na.rm = TRUE),
            zoom = DEFAULT_ZOOM_LEVEL
          )
      } else {
        map <- map %>%
          fitBounds(
            lng1 = min(data$lon, na.rm = TRUE),
            lat1 = min(data$lat, na.rm = TRUE),
            lng2 = max(data$lon, na.rm = TRUE),
            lat2 = max(data$lat, na.rm = TRUE),
            options = list(maxZoom = map_tile_max_native_zoom)
          )
      }

      return(map)
    })

    hide("loading-spinner")
    runjs("document.getElementById('map').style.visibility = 'visible';")
  }
)

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
