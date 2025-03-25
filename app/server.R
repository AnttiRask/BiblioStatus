# Load required libraries
library(dplyr)
library(here)
library(leaflet)
library(RSQLite)
library(shiny)
library(shinyjs)

# Uncomment for the local version
source(here("app/www/functions.R"))
source(here("app/www/variables.R"))

# source("www/functions.R")
# source("www/variables.R")

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
            
            tiles <- reactive({
                if (input$dark_mode) {
                    providers$CartoDB.DarkMatter
                } else {
                    providers$CartoDB.Positron
                }
            })
            
            map <- leaflet(data) %>%
                clearMarkers() %>%
                addProviderTiles(tiles()) %>%
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
                        zoom = 11
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
