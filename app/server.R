# Load required libraries
library(dplyr)
library(here)
library(leaflet)
library(RSQLite)
library(shiny)
library(shinyjs)

# Uncomment for the local version
# source(here("app/www/functions.R"))
# source(here("app/www/variables.R"))

source("www/functions.R")
source("www/variables.R")

server <- function(input, output, session) {
    # Create a reactiveVal to store library data
    library_data <- reactiveVal(NULL)
    
    # Function to fetch and process data (only called on refresh)
    refresh_data <- function() {
        libraries <- fetch_libraries()
        schedules <- fetch_schedules()
        
        now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")
        
        schedules <- schedules %>%
            mutate(
                is_open_now = from <= now & to >= now,
                open_status = case_when(
                    status_label == "Closed for the whole day" ~ "Closed for the whole day",
                    is_open_now & status_label == "Open" ~ "Open",
                    is_open_now & status_label == "Self-service" ~ "Self-service",
                    is_open_now & status_label == "Temporarily closed" ~ "Temporarily closed",
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
    
    observeEvent(input$refresh, {
        refresh_data()
    }, ignoreNULL = FALSE)
    
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
    
    # Combined observer to update map when either city or dark mode changes
    observeEvent({input$city_filter; input$dark_mode; library_data()}, {
        req(input$city_filter)
        data <- library_data() %>% filter(city_name == input$city_filter)
        req(nrow(data) > 0)
        
        tile_provider <- if (input$dark_mode) {
            providers$CartoDB.DarkMatter
        } else {
            providers$CartoDB.Positron
        }
        
        output$map <- renderLeaflet({
            map <- leaflet(data) %>%
                addProviderTiles(tile_provider, group = "basemap") %>%
                addCircleMarkers(
                    lng = ~lon,
                    lat = ~lat,
                    color = ~ case_when(
                        open_status == "Open" ~ Blue,
                        open_status == "Self-service" ~ Yellow,
                        open_status %in% c("Closed", "Temporarily closed") ~ Red,
                        open_status == "Closed for the whole day" ~ Gray,
                        TRUE ~ Purple
                    ),
                    radius = 8,
                    popup = ~ paste(
                        if_else(
                            !is.na(library_url),
                            paste0("<b><a href='", library_url, "' target='_blank'>", library_branch_name, "</a></b>"),
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
                        if_else(
                            !is.na(library_services),
                            paste("<br>", "<br>", "<b>Services (in Finnish): </b>", "<br>", library_services),
                            ""
                        )
                    ),
                    label = ~library_branch_name
                ) %>%
                addLegend(
                    position = "topright",
                    colors = c(Blue, Yellow, Red, Gray),
                    labels = c("Open", "Self-service", "Closed", "Closed for the whole day"),
                    title = "Status"
                )
            
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
    })
}
