# Load required libraries
library(dplyr)
library(here)
library(leaflet)
library(purrr)
library(RSQLite)
library(shiny)
library(shinyjs)

# Load helper functions and variables
source("www/functions.R")
source("www/variables.R")
source("modules/service_stats.R")

# Uncomment for the local version
# source(here("app/www/functions.R"))
# source(here("app/www/variables.R"))
# source(here("app/modules/service_stats.R"))

# Marker sizing, zoom, and result-count tuning (mobile gets larger touch targets)
MOBILE_MARKER_RADIUS <- 10
DESKTOP_MARKER_RADIUS <- 8
MOBILE_NEAREST_MARKER_RADIUS <- 12
DESKTOP_NEAREST_MARKER_RADIUS <- 10
USER_LOCATION_MARKER_RADIUS <- 10
MOBILE_POPUP_MAX_WIDTH <- 250
MOBILE_POPUP_MIN_WIDTH <- 200
DESKTOP_POPUP_MAX_WIDTH <- 300
DESKTOP_POPUP_MIN_WIDTH <- 100
DEFAULT_ZOOM_LEVEL <- 11
SINGLE_LIBRARY_ZOOM_THRESHOLD <- 2
MOBILE_NEAREST_COUNT <- 3
DESKTOP_NEAREST_COUNT <- 5

carto_attribution <- paste0(
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors ',
  '&copy; <a href="https://carto.com/attributions">CARTO</a>'
)

server <- function(input, output, session) {
  # Reconnect (not full page reload) if the websocket drops, e.g. after
  # network blips or Cloud Run recycling the connection.
  session$allowReconnect(TRUE)

  # State: reactive containers
  library_data <- reactiveVal(NULL)
  selected_library <- reactiveVal(NULL)
  user_location <- reactiveVal(NULL)
  nearest_libraries <- reactiveVal(NULL)
  all_library_schedules <- reactiveVal(NULL)
  library_services_data <- reactiveVal(NULL)
  startup_city_set  <- reactiveVal(FALSE)    # Tracks whether initial city has been set
  startup_city      <- reactiveVal("Helsinki") # City determined on startup (geolocation / fallback)
  # Committed filter state — what the map currently shows.
  # Set by the "Show on Map" button or by startup; not updated by cascade observers.
  committed_city    <- reactiveVal("")
  committed_service <- reactiveVal("")
  committed_library <- reactiveVal("")
  # Server-side mirror of the service/library dropdown selections, used by
  # "Show on Map" instead of reading input$service_filter/input$library_search
  # directly. Needed because updateSelectInput()/updateSelectizeInput() (used
  # by the × clear buttons) only take effect in the browser and echo back to
  # input$* asynchronously over the websocket — reading input$* immediately
  # after a clear can still see the pre-clear value if "Show on Map" is
  # clicked before that round-trip completes. These reactiveVals are instead
  # written synchronously by every path that changes the selection.
  pending_service <- reactiveVal("")
  pending_library <- reactiveVal("")

  # Rebuild the service dropdown's choices to only services offered by the
  # given set of library ids (a single selected library, or every library in
  # a city), re-affirming the current selection if it's still valid among
  # those choices or resetting it to "All Services" otherwise. Returns the
  # new selection so callers can keep pending_service() in sync.
  update_service_choices_for_libraries <- function(lib_ids, all_svcs, current_service) {
    svc_choices <- stringr::str_sort(
      unique(all_svcs %>% filter(library_id %in% lib_ids) %>% pull(service_name)),
      locale = "fi"
    )
    still_valid <- !is.null(current_service) && current_service %in% svc_choices
    new_service <- if (still_valid) current_service else ""
    updateSelectInput(session, "service_filter",
      choices = c("All Services" = "", svc_choices),
      selected = new_service)
    new_service
  }

  # Data fetching and processing
  refresh_data <- function() {
    libraries <- fetch_libraries()
    schedules <- fetch_schedules()
    services <- fetch_library_services()

    now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")

    # Add computed fields to schedules
    schedules <- schedules %>%
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

    # Store ALL schedules for detail panel
    all_library_schedules(schedules)

    # Create map display version (one status per library for marker colors)
    map_display <- schedules %>%
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

    # Join libraries with map display data
    data <- libraries %>%
      left_join(map_display, by = join_by(id == library_id))

    library_data(data)
    library_services_data(services)
  }

  # Initial fetch and manual refresh
  observeEvent(
    input$refresh,
    {
      refresh_data()
    },
    ignoreNULL = FALSE
  )

  # Populate all filter selectors on data load
  observe({
    all_libs <- library_data()
    all_svcs <- library_services_data()
    req(all_libs, all_svcs)

    city_choices <- stringr::str_sort(unique(all_libs$city_name), locale = "fi")
    lib_choices  <- all_libs %>%
      arrange(library_branch_name) %>%
      { setNames(as.character(.$id), .$library_branch_name) }
    svc_choices  <- stringr::str_sort(unique(all_svcs$service_name), locale = "fi")

    isolate({
      updateSelectInput(session, "city_filter",
        choices = c("All Cities" = "", city_choices), selected = "")
      updateSelectizeInput(session, "library_search",
        choices = c("All Libraries" = "", lib_choices), server = TRUE)
      updateSelectInput(session, "service_filter",
        choices = c("All Services" = "", svc_choices), selected = "")
    })
  })

  # Startup geolocation: set city to nearest library's city
  observeEvent(input$startup_location, {
    req(!startup_city_set())
    all_libs <- library_data()
    req(all_libs)
    startup_city_set(TRUE)

    loc <- input$startup_location
    nearest_city <- all_libs %>%
      mutate(dist = (lat - loc$lat)^2 + (lon - loc$lon)^2) %>%
      arrange(dist) %>%
      slice(1) %>%
      pull(city_name)

    startup_city(nearest_city)
    updateSelectInput(session, "city_filter", selected = nearest_city)
    committed_city(nearest_city)  # triggers initial map render (no browser round-trip needed)
  })

  # Startup geolocation failed or timed out: default to Helsinki
  observeEvent(input$startup_geolocation_failed, {
    req(!startup_city_set())
    startup_city_set(TRUE)
    updateSelectInput(session, "city_filter", selected = "Helsinki")
    committed_city("Helsinki")  # triggers initial map render
  })

  observeEvent(input$startup_geolocation_timeout, {
    req(!startup_city_set())
    startup_city_set(TRUE)
    updateSelectInput(session, "city_filter", selected = "Helsinki")
    committed_city("Helsinki")  # triggers initial map render
  })

  # Library selectize: selecting a library auto-updates the city dropdown and
  # narrows the service dropdown to just that library's own services (city
  # cascade only narrows service to the whole city's aggregate). Clearing the
  # library (selected == "") widens service back out to the current city's
  # scope instead, since there's no more specific library to narrow it to.
  observeEvent(input$library_search, {
    all_libs <- library_data()
    all_svcs <- library_services_data()
    req(all_libs, all_svcs)

    if (input$library_search == "") {
      current_city <- isolate(input$city_filter)
      city_lib_ids <- if (!is.null(current_city) && current_city != "") {
        all_libs %>% filter(city_name == current_city) %>% pull(id)
      } else {
        all_libs$id
      }
      new_service <- update_service_choices_for_libraries(
        city_lib_ids, all_svcs, isolate(input$service_filter))
      pending_service(new_service)
      return()
    }

    selected_lib <- all_libs %>% filter(id == as.numeric(input$library_search))
    req(nrow(selected_lib) > 0)

    updateSelectInput(session, "city_filter",
      selected = selected_lib$city_name[1])

    new_service <- update_service_choices_for_libraries(
      selected_lib$id, all_svcs, isolate(input$service_filter))
    pending_service(new_service)
  }, ignoreInit = TRUE, ignoreNULL = FALSE)

  # Cascading: city → update library choices, and service choices+selection.
  # City itself is NOT updated by the other two — that bidirectional dependency
  # caused stale-read race conditions where one cascade re-injected an outdated
  # value from another input (e.g. old service coming back after × clear).
  # City choices stay as "all cities" (set by the populate observer on data load).
  observeEvent(input$city_filter, {
    all_libs <- library_data()
    all_svcs <- library_services_data()
    req(all_libs, all_svcs)

    current_service <- isolate(input$service_filter)

    city_lib_ids <- if (!is.null(input$city_filter) && input$city_filter != "") {
      all_libs %>% filter(city_name == input$city_filter) %>% pull(id)
    } else {
      all_libs$id
    }

    # Library choices = intersection of city + service filters
    filtered_ids <- city_lib_ids
    if (!is.null(current_service) && current_service != "") {
      svc_ids <- all_svcs %>% filter(service_name == current_service) %>% pull(library_id)
      filtered_ids <- intersect(filtered_ids, svc_ids)
    }

    lib_choices <- all_libs %>%
      filter(id %in% filtered_ids) %>%
      arrange(library_branch_name) %>%
      { setNames(as.character(.$id), .$library_branch_name) }

    # This city change may be the side effect of picking a specific library
    # (library_search's own observer sets city_filter to that library's city).
    # If pending_library() still refers to a library that's valid in this new
    # city, keep it selected and keep the library-scoped service choices
    # library_search's observer already set - don't reset either back out to
    # "no library" / city-wide service, which would immediately undo that pick.
    still_picked_lib_id <- pending_library()
    library_pick_still_valid <- !is.null(still_picked_lib_id) &&
      still_picked_lib_id != "" && as.numeric(still_picked_lib_id) %in% city_lib_ids

    updateSelectizeInput(session, "library_search",
      choices = c("All Libraries" = "", lib_choices), server = TRUE,
      selected = if (library_pick_still_valid) still_picked_lib_id else "")
    if (!library_pick_still_valid) {
      pending_library("")
    }

    # Service choices = only services offered by libraries in the selected city
    # (matches the library dropdown's own city scoping, so a service that has
    # zero results in this city can't even be picked). Re-affirm the current
    # selection if it's still valid there, otherwise reset it to "All Services".
    # Skipped when a library pick is still valid above - that already scoped
    # service choices to just that library, which is narrower/more correct.
    if (!library_pick_still_valid) {
      new_service <- update_service_choices_for_libraries(city_lib_ids, all_svcs, current_service)
      pending_service(new_service)
    }

    # Reset state when city changes
    nearest_libraries(NULL)
    user_location(NULL)
    selected_library(NULL)
  }, ignoreInit = TRUE)

  # Cascading: service → update library choices only.
  # Service choices stay as "all services" (set by the populate observer on data load).
  # ignoreNULL = FALSE: must fire when service is cleared to "" (isTruthy("") = FALSE).
  observeEvent(input$service_filter, {
    pending_service(input$service_filter)

    all_libs <- library_data()
    all_svcs <- library_services_data()
    req(all_libs, all_svcs)

    current_city <- isolate(input$city_filter)

    # Library choices = intersection of service + city filters
    filtered_ids <- all_libs$id
    if (!is.null(input$service_filter) && input$service_filter != "") {
      svc_ids <- all_svcs %>% filter(service_name == input$service_filter) %>% pull(library_id)
      filtered_ids <- intersect(filtered_ids, svc_ids)
    }
    if (!is.null(current_city) && current_city != "") {
      city_ids <- all_libs %>% filter(city_name == current_city) %>% pull(id)
      filtered_ids <- intersect(filtered_ids, city_ids)
    }

    lib_choices <- all_libs %>%
      filter(id %in% filtered_ids) %>%
      arrange(library_branch_name) %>%
      { setNames(as.character(.$id), .$library_branch_name) }

    updateSelectizeInput(session, "library_search",
      choices = c("All Libraries" = "", lib_choices), server = TRUE, selected = "")
  }, ignoreInit = TRUE, ignoreNULL = FALSE)

  # Mirror library_search into pending_library on every real change (selecting
  # a library, or the cascades above resetting it to "" on city/service change).
  observeEvent(input$library_search, {
    pending_library(input$library_search)
  }, ignoreInit = TRUE, ignoreNULL = FALSE)

  # Individual clear buttons — each clears one filter; cascades handle downstream updates.
  # Also write through to committed_* AND pending_* so the map updates immediately
  # (without requiring "Show on Map") and so a subsequent "Show on Map" click commits
  # the clear even if the browser round-trip for input$service_filter/library_search
  # (triggered by updateSelectInput/updateSelectizeInput below) hasn't landed yet.
  observeEvent(input$clear_library, {
    updateSelectizeInput(session, "library_search", selected = "")
    pending_library("")

    # Widen the service dropdown back out to the current city's scope: it may
    # have been narrowed to just this library's own services, and there's no
    # more specific library left to scope it to.
    all_libs <- library_data()
    all_svcs <- library_services_data()
    req(all_libs, all_svcs)
    current_city <- isolate(input$city_filter)
    city_lib_ids <- if (!is.null(current_city) && current_city != "") {
      all_libs %>% filter(city_name == current_city) %>% pull(id)
    } else {
      all_libs$id
    }
    new_service <- update_service_choices_for_libraries(
      city_lib_ids, all_svcs, isolate(input$service_filter))
    pending_service(new_service)

    selected_library(NULL)
    committed_library("")
  })

  observeEvent(input$clear_service, {
    updateSelectInput(session, "service_filter", selected = "")
    pending_service("")

    # Also clear the library filter: its narrowed choice list (and any
    # selection within it) was a side effect of the service filter, not an
    # independent choice, so there's no valid library selection left to keep.
    # Rebuild the choice list too (not just the selection) - scoped to the
    # current city only, since the service constraint is now gone - otherwise
    # the dropdown's options stay stuck at the pre-clear, service-filtered set
    # even though the map and the selected value both reset correctly.
    all_libs <- library_data()
    req(all_libs)
    current_city <- isolate(input$city_filter)
    city_lib_ids <- if (!is.null(current_city) && current_city != "") {
      all_libs %>% filter(city_name == current_city) %>% pull(id)
    } else {
      all_libs$id
    }
    lib_choices <- all_libs %>%
      filter(id %in% city_lib_ids) %>%
      arrange(library_branch_name) %>%
      { setNames(as.character(.$id), .$library_branch_name) }
    updateSelectizeInput(session, "library_search",
      choices = c("All Libraries" = "", lib_choices), server = TRUE, selected = "")
    pending_library("")
    committed_library("")
    selected_library(NULL)
    committed_service("")
  })

  # "Show on Map" button: commit current dropdown state and re-render the map.
  # Uses pending_service()/pending_library() rather than input$service_filter/
  # input$library_search directly — see the pending_* reactiveVal declarations
  # above for why reading input$* here can see a stale, pre-clear value.
  # Also activates the library detail sidebar when a specific library is selected.
  observeEvent(input$apply_filters, {
    committed_city(input$city_filter)
    committed_service(pending_service())
    committed_library(pending_library())

    lib_id <- pending_library()
    if (!is.null(lib_id) && lib_id != "") {
      selected_lib <- library_data() %>% filter(id == as.numeric(lib_id))
      selected_library(if (nrow(selected_lib) > 0) selected_lib else NULL)
    } else {
      selected_library(NULL)
    }
  })

  # Render map when committed filter state, dark mode, or underlying data changes.
  # Committed state is only updated by the "Show on Map" button or startup — so
  # cascade observers updating dropdowns never trigger a premature map re-render.
  observeEvent(
    {
      committed_city()
      committed_service()
      committed_library()
      input$dark_mode
      library_data()
    },
    {
      req(library_data())
      req(startup_city_set())  # wait until startup city is determined

      # Start with all libraries
      data <- library_data()

      city_val    <- committed_city()
      service_val <- committed_service()
      library_val <- committed_library()

      # Apply city filter
      if (!is.null(city_val) && city_val != "") {
        data <- data %>% filter(city_name == city_val)
      }

      # Apply service filter
      if (!is.null(service_val) && service_val != "") {
        services_data <- library_services_data()
        req(services_data)

        lib_ids_with_service <- services_data %>%
          filter(service_name == service_val) %>%
          pull(library_id)

        data <- data %>% filter(id %in% lib_ids_with_service)
      }

      # Apply specific library filter
      if (!is.null(library_val) && library_val != "") {
        data <- data %>% filter(id == as.numeric(library_val))
      }

      # Self-heal: if committed library id produces 0 rows, clear it.
      if (nrow(data) == 0 && !is.null(library_val) && library_val != "") {
        updateSelectizeInput(session, "library_search", selected = "")
        pending_library("")
        committed_library("")
        return()
      }
      req(nrow(data) > 0)

      tile_variant <- if (isTRUE(input$dark_mode)) "dark_all" else "light_all"
      tile_url <- paste0(
        "https://{s}.basemaps.cartocdn.com/", tile_variant,
        "/{z}/{x}/{y}{r}.png?key=", CARTO_API_KEY
      )

      output$map <- renderLeaflet({
        chosen_colors <- if (isTRUE(input$dark_mode)) dark_colors else light_colors

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
          addTiles(
            urlTemplate = tile_url,
            group = "basemap",
            options = tileOptions(subdomains = "abcd", attribution = carto_attribution)
          ) %>%
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
              "Open",
              "Self-service",
              "Closed",
              "Closed for the whole day"
            ),
            title = "Status"
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
              lat2 = max(data$lat, na.rm = TRUE)
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
      showNotification("No open libraries found nearby", type = "warning")
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

    tile_provider <- if (isTRUE(input$dark_mode)) {
      providers$CartoDB.DarkMatter
    } else {
      providers$CartoDB.Positron
    }

    chosen_colors <- if (isTRUE(input$dark_mode)) dark_colors else light_colors

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
        lat2 = max(all_lats) + 0.01
      )
  }

  # Error display UI
  output$geolocation_error_ui <- renderUI({
    req(input$geolocation_error)
    div(class = "alert alert-danger", role = "alert",
      style = "margin: 10px 0; padding: 10px;",
      icon("exclamation-triangle"), " ", input$geolocation_error)
  })

  # Nearest libraries display UI
  output$nearest_libraries_ui <- renderUI({
    nearest <- nearest_libraries()
    req(nearest)
    req(nrow(nearest) > 0)

    tagList(
      h4("Nearest Open Libraries:", style = "color: #C1272D;"),
      lapply(1:nrow(nearest), function(i) {
        lib <- nearest[i, ]
        maps_url <- sprintf(
          "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f",
          lib$lat, lib$lon
        )
        div(
          style = "margin-bottom: 15px; padding: 10px; border-left: 3px solid #C1272D; background-color: rgba(193, 39, 45, 0.05);",
          tags$b(lib$library_branch_name),
          br(),
          tags$small(lib$city_name),
          br(),
          tags$small(style = "color: #C1272D; font-weight: bold;",
            lib$distance_display),
          br(),
          tags$a(
            href = maps_url,
            target = "_blank",
            class = "btn btn-sm btn-directions mt-2",
            icon("location-arrow"), " Get Directions"
          )
        )
      })
    )
  })

  # Sidebar panel with library info
  output$library_services <- renderUI({
    selected <- selected_library()
    req(selected)
    schedules <- all_library_schedules()

    {
      maps_url <- sprintf(
        "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f",
        selected$lat, selected$lon
      )

      # Get current time for schedule formatting
      now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")

      # Format all schedule periods
      schedule_html <- if (!is.null(schedules)) {
        format_schedule_periods(selected$id, schedules, now)
      } else {
        "<p>No schedule information available</p>"
      }

      tagList(
        h4(selected$library_branch_name),
        p(selected$library_address),

        # Current status (prominently displayed)
        tags$b("Current Status:"),
        p(selected$open_status),

        # Today's full schedule
        tags$b("Today's Schedule:"),
        HTML(schedule_html),
        br(),

        # Contact information (phone)
        if (!is.na(selected$library_phone)) {
          tagList(
            tags$a(
              href = paste0("tel:", selected$library_phone),
              icon("phone"), " ", selected$library_phone,
              style = "display: block; margin-bottom: 8px; color: #C1272D; text-decoration: none;"
            )
          )
        },

        # Contact information (email)
        if (!is.na(selected$library_email)) {
          tagList(
            tags$a(
              href = paste0("mailto:", selected$library_email),
              icon("envelope"), " ", selected$library_email,
              style = "display: block; margin-bottom: 8px; color: #C1272D; text-decoration: none;"
            )
          )
        },
        br(),

        # Get Directions button
        tags$a(
          href = maps_url,
          target = "_blank",
          class = "btn btn-sm btn-directions mb-3",
          icon("location-arrow"), " Get Directions"
        ),

        # Services
        tags$b("Services (in Finnish):"),
        {
          services <- library_services_data()
          if (!is.null(services)) {
            lib_services <- services %>%
              filter(library_id == selected$id) %>%
              pull(service_name) %>%
              sort()

            if (length(lib_services) > 0) {
              # Display as visual badges
              div(
                class = "service-badges mt-2",
                lapply(lib_services, function(svc) {
                  span(
                    svc,
                    class = "badge",
                    style = "display: inline-block; background-color: #e3f2fd; color: #1976d2;
                             padding: 6px 12px; margin: 3px; border-radius: 6px;
                             font-size: 13px; font-weight: 500; line-height: 1.5;"
                  )
                })
              )
            } else {
              p("No services listed", style = "color: #888; font-style: italic; margin-top: 8px;")
            }
          }
        }
      )
    }
  })

  # Service Statistics module (is_dark_mode is set via JS MutationObserver)
  service_stats_server("stats", library_services_data, library_data,
                       reactive(input$is_dark_mode))
}
