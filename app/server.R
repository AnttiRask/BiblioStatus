# Load required libraries
library(dplyr)
library(here)
library(leaflet)
library(RSQLite)
library(shiny)
library(shinyjs)

# Uncomment for the local version
# source(here("app/www/functions.R"))

source("www/functions.R")

server <- function(input, output, session) {
  # Create a reactiveVal to store library data
  library_data <- reactiveVal(NULL)

  # Function to fetch and process data (only called on refresh)
  refresh_data <- function() {
    libraries <- fetch_libraries()
    schedules <- fetch_schedules()

    now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")

    # Compute is_open_now dynamically in the app, not in the database
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
        ),
        opening_hours = if_else(
          is_open_now,
          paste0(from, " - ", to),
          NA_character_
        )
      )

    # Join libraries with schedules and determine status
    data <- libraries %>%
      left_join(schedules, by = join_by(id == library_id)) %>%
      group_by(id) %>%
      arrange(desc(is_open_now), desc(to)) %>%
      slice(1) %>%
      ungroup()

    # Store in reactiveVal
    library_data(data)
  }

  # Trigger refresh only when the user presses the button
  observeEvent(
    input$refresh,
    {
      refresh_data()
    },
    # Ensures it runs at least once on app startup
    ignoreNULL = FALSE
  )

  # Populate city dropdown dynamically
  observe({
    # Prevent unnecessary reactivity
    data <- isolate(library_data())
    # Ensure data is available before proceeding
    req(data)
    city_choices <- city_choices <- sort(unique(data$city_name))
    # fmt: skip
    updateSelectInput(
            session,
            "city_filter",
            choices  = city_choices,
            selected = "Helsinki"
        )
  })

  # Render map based on selected city
  observe({
    # Avoid unnecessary reactivity
    data <- isolate(library_data())

    # Ensure data exists before proceeding
    req(data)

    # Filter by selected city
    data <- data %>% filter(city_name == input$city_filter)

    # Prevent errors if no libraries exist for the selected city
    if (nrow(data) == 0) {
      return(NULL) # Stops execution
    }

    output$map <- renderLeaflet({
      map <- leaflet(data) %>%
        clearMarkers() %>%
        addProviderTiles(providers$CartoDB.Positron) %>%
        addCircleMarkers(
          lng = ~lon,
          lat = ~lat,
          color = ~ case_when(
            open_status == "Open" ~ "green",
            open_status == "Self-service" ~ "orange",
            open_status %in% c("Closed", "Temporarily closed") ~ "red",
            open_status == "Closed for the whole day" ~ "darkgray",
            TRUE ~ "black"
          ),
          radius = 8,
          popup = ~ paste(
            "<b>",
            library_branch_name,
            "</b><br>",
            "City/Municipality: ",
            city_name,
            "</b><br>",
            "Status: ",
            open_status,
            "</b><br>",
            if_else(
              !is.na(opening_hours),
              paste("Hours: ", opening_hours),
              ""
            )
          ),
          label = ~library_branch_name
        ) %>%
        addLegend(
          position = "topright",
          colors = c("green", "orange", "red", "darkgray"),
          labels = c(
            "Open",
            "Self-service",
            "Closed",
            "Closed for the whole day"
          ),
          title = "Status"
        )

      # Adjust map view based on number of locations
      if (data %>% distinct(id) %>% nrow() <= 2) {
        map <- map %>%
          setView(
            lat = mean(data$lat, na.rm = TRUE),
            lng = mean(data$lon, na.rm = TRUE),
            zoom = 12
          )
      } else if (data %>% distinct(id) %>% nrow() > 2) {
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
  })
}
