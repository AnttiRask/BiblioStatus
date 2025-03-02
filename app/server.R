# Load required libraries
library(dplyr)
library(duckdb)
library(leaflet)
library(shiny)
library(shinyjs)

source("www/functions.R")

server <- function(input, output, session) {
  # Load libraries and schedules from DuckDB
  library_data <- reactive({
    libraries <- fetch_libraries()
    schedules <- fetch_schedules()

    # Join the data and determine real-time open status
    data <- libraries %>%
      left_join(schedules, by = join_by(id == library_id)) %>%
      group_by(id) %>%
      arrange(desc(is_open_now), desc(to)) %>%
      slice(1) %>%
      ungroup()

    return(data)
  })

  # Populate city dropdown dynamically
  observe({
    # fmt: skip
    data         <- library_data()
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
    data <- library_data() %>% filter(city_name == input$city_filter)

    # Prevent errors if no libraries exist for the selected city
    if (nrow(data) == 0) {
      showNotification("No libraries found for this city.", type = "warning")
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

      if (data %>% distinct(id) %>% nrow() == 1) {
        map <- map %>%
          setView(
            lat = mean(data$lat, na.rm = TRUE),
            lng = mean(data$lon, na.rm = TRUE),
            zoom = 13
          )
      }
      if (data %>% distinct(id) %>% nrow() > 1) {
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

  # Refresh data on button click
  observeEvent(input$refresh, {
    # Triggers reactivity to update status
    library_data()
  })
}
