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

# Uncomment for the local version
# source(here("app/www/functions.R"))
# source(here("app/www/variables.R"))

server <- function(input, output, session) {
  # State: reactive containers
  library_data <- reactiveVal(NULL)
  selected_library <- reactiveVal(NULL)
  user_location <- reactiveVal(NULL)
  nearest_libraries <- reactiveVal(NULL)
  all_library_schedules <- reactiveVal(NULL)
  library_services_data <- reactiveVal(NULL)

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

  # Populate city selector
  observe({
    data <- isolate(library_data())
    req(data)
    city_choices <- sort(unique(data$city_name))
    updateSelectInput(
      session,
      "city_filter",
      choices = city_choices,
      selected = "Helsinki"
    )
  })

  # Update map on city/dark mode chang
  observeEvent(
    {
      input$city_filter
      input$dark_mode
      library_data()
    },
    {
      req(input$city_filter)
      req(library_data())
      data <- library_data() %>% filter(city_name == input$city_filter)
      req(nrow(data) > 0)

      tile_provider <- if (isTRUE(input$dark_mode)) {
        providers$CartoDB.DarkMatter
        } else {
          providers$CartoDB.Positron
          }

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
          addProviderTiles(tile_provider, group = "basemap") %>%
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
            radius = if (isTRUE(input$is_mobile)) 10 else 8,  # Larger markers on mobile
            popup = ~ paste(
              if_else(
                !is.na(library_url),
                paste0(
                  "<b><a href='",
                  library_url,
                  "' target='_blank'>",
                  library_branch_name,
                  "</a></b>"
                ),
                paste0("<b>", library_branch_name, "</b>")
              ),
              "<br>",
              library_address,
              "<br>",
              "<br>",
              "<b>Status: </b>",
              open_status,
              "<br>",
              if_else(
                !is.na(opening_hours),
                paste("<b>Hours: </b>", opening_hours),
                "<b>Hours: </b>NA"
              ),
              "<br>",
              sprintf(
                "📍 <a href='https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f' target='_blank' style='color: #C1272D; font-weight: bold;'>Get Directions</a>",
                lat, lon
              )
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
              maxWidth = if (isTRUE(input$is_mobile)) 250 else 300,
              minWidth = if (isTRUE(input$is_mobile)) 200 else 100,
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
        if (data %>% distinct(id) %>% nrow() <= 2) {
          map <- map %>%
            setView(
              lat = mean(data$lat, na.rm = TRUE),
              lng = mean(data$lon, na.rm = TRUE),
              zoom = 11
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

  # Reset selected library on city change
  observeEvent(input$city_filter, {
    if (!is.null(input$city_filter) && input$city_filter != "") {
      nearest_libraries(NULL)
      user_location(NULL)
    }
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
      head(if (isTRUE(input$is_mobile)) 3 else 5)

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
        radius = 10,
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
          open_status == "Open" ~ chosen_colors$Open,
          open_status == "Self-service" ~ chosen_colors$Self,
          TRUE ~ chosen_colors$Unknown
        ),
        radius = if (isTRUE(input$is_mobile)) 12 else 10,
        popup = ~ paste(
          if_else(
            !is.na(library_url),
            paste0("<b><a href='", library_url, "' target='_blank'>",
                   library_branch_name, "</a></b>"),
            paste0("<b>", library_branch_name, "</b>")
          ),
          "<br>", library_address,
          "<br><b>Distance: </b>", distance_display,
          "<br><b>Status: </b>", open_status,
          "<br>",
          sprintf(
            "📍 <a href='https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f' target='_blank' style='color: #C1272D; font-weight: bold;'>Get Directions</a>",
            lat, lon
          )
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
    div(class = "alert alert-danger", style = "margin: 10px 0; padding: 10px;",
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

    if (!is.null(selected$library_services)) {
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
        p({
          services <- library_services_data()
          if (!is.null(services)) {
            lib_services <- services %>%
              filter(library_id == selected$id) %>%
              pull(service_name) %>%
              sort()

            if (length(lib_services) > 0) {
              paste(lib_services, collapse = ", ")
            } else {
              "No services listed"
            }
          } else {
            selected$library_services  # Fallback to old column if new data not loaded
          }
        })
      )
    }
  })
}
