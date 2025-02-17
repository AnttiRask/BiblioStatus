library(dplyr)
library(httr)
library(jsonlite)
library(leaflet)
library(purrr)
library(shiny)
library(shinyjs)

source("www/functions.R")

server <- function(input, output, session) {
    session_data <- reactiveValues(
        libraries = NULL,
        schedules = NULL
    )
    
    library_data <- reactive({
        libraries <- fetch_libraries(session_data)
        data      <- fetch_schedules(libraries, session_data)
        return(data)
    })
    
    observe({
        data         <- library_data()
        city_choices <- unique(data$city_name)
        updateSelectInput(session, "city_filter", choices = city_choices, selected = "Helsinki")
    })
    
    observe({
        data          <- library_data()
        filtered_data <- data %>% filter(city_name == input$city_filter)
        
        output$map <- renderLeaflet({
            if (nrow(filtered_data) == 0) {
                leaflet() %>%
                    addProviderTiles(providers$CartoDB.Positron)
            } else {
                leaflet(filtered_data) %>%
                    addProviderTiles(providers$CartoDB.Positron) %>%
                    fitBounds(
                        lng1 = min(filtered_data$lon), lat1 = min(filtered_data$lat),
                        lng2 = max(filtered_data$lon), lat2 = max(filtered_data$lat)
                    ) %>%
                    addCircleMarkers(
                        lng   = ~lon,
                        lat   = ~lat,
                        color = ~case_when(
                            open_status == "Open"                     ~ "green",
                            open_status == "Self-service"             ~ "orange",
                            open_status == "Closed"                   ~ "red",
                            open_status == "Closed for the whole day" ~ "darkgray",
                            open_status == "Temporarily closed"       ~ "lightgray",
                            TRUE                                      ~ "black"
                        ),
                        radius = 8,
                        popup  = ~paste(
                            "<b>", library_branch_name, "</b><br>",
                            "City: ", city_name, "</b><br>",
                            "Status: ", open_status, "</b><br>",
                            if_else(!is.na(opening_hours), paste("Hours: ", opening_hours), "")
                        ),
                        label = ~library_branch_name
                    ) %>%
                    addLegend(
                        position = "topright",
                        colors   = c("green", "orange", "red", "darkgray", "lightgray"),
                        labels   = c("Open", "Self-service", "Closed", "Closed for the whole day", "Temporarily closed"),
                        title    = "Status"
                    )
            }
        })
        
        hide("loading-spinner")
        runjs("document.getElementById('map').style.visibility = 'visible';")
    })
}