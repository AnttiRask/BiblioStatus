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

  # Data fetching and processing
  refresh_data <- function() {
    libraries <- fetch_libraries()
    schedules <- fetch_schedules()

    now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")

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

    data <- libraries %>%
      left_join(schedules, by = join_by(id == library_id)) %>%
      group_by(id) %>%
      arrange(desc(is_open_now), desc(to)) %>%
      slice(1) %>%
      ungroup()

    library_data(data)
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
      data <- library_data() %>% filter(city_name == input$city_filter)
      req(nrow(data) > 0)

      tile_provider <- if (input$dark_mode) {
        providers$CartoDB.DarkMatter
      } else {
        providers$CartoDB.Positron
      }

      output$map <- renderLeaflet({
        chosen_colors <- if (input$dark_mode) dark_colors else light_colors

        map <- leaflet(data) %>%
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
            radius = 8,
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
    selected_library(NULL)
  })

  # Sidebar panel with library info
  output$library_services <- renderUI({
    if (isTRUE(input$is_mobile)) return(NULL)

    selected <- selected_library()
    req(selected)

    if (!is.null(selected$library_services)) {
      tagList(
        h4(selected$library_branch_name),
        p(selected$library_address),
        tags$b("Status:"),
        p(selected$open_status),
        tags$b("Hours:"),
        p(selected$opening_hours),
        tags$b("Services (in Finnish):"),
        p(selected$library_services)
      )
    }
  })
}
