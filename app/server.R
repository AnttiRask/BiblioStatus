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
        data <- fetch_schedules(libraries, session_data)
        return(data)
    })
    
    observeEvent(library_data(), {
        data <- library_data()
        
        output$map <- renderLeaflet({
            leaflet(data) %>%
                addProviderTiles(providers$CartoDB.Positron) %>%
                fitBounds(
                    lng1 = min(data$lon), lat1 = min(data$lat),
                    lng2 = max(data$lon), lat2 = max(data$lat)
                ) %>%
                addCircleMarkers(
                    lng         = ~lon,
                    lat         = ~lat,
                    color       = ~case_when(
                        open_status == "Open"                     ~ "green",
                        open_status == "Closed"                   ~ "red",
                        open_status == "Closed for the whole day" ~ "darkgray",
                        open_status == "Temporarily closed"       ~ "lightgray",
                        open_status == "Self-service"             ~ "yellow",
                        TRUE                                      ~ "black"
                    ),
                    radius      = 8,
                    popup       = ~paste(
                        "<b>", library_branch_name, "</b><br>",
                        "Status: ", open_status, "</b><br>",
                        "Hours: ", opening_hours
                    ),
                    label       = ~library_branch_name
                )
        })
        
        hide("loading-spinner")
        runjs("document.getElementById('map').style.visibility = 'visible';")
    }, ignoreNULL = FALSE)
    
    observeEvent(input$refresh, {
        session_data$schedules <- NULL
        updated_data <- fetch_schedules(fetch_libraries(session_data), session_data)
        leafletProxy("map", data = updated_data) %>%
            clearMarkers() %>%
            addCircleMarkers(
                lng         = ~lon,
                lat         = ~lat,
                color       = ~case_when(
                    open_status == "Open"                     ~ "green",
                    open_status == "Closed"                   ~ "red",
                    open_status == "Closed for the whole day" ~ "darkgray",
                    open_status == "Temporarily closed"       ~ "lightgray",
                    open_status == "Self-service"             ~ "yellow",
                    TRUE                                      ~ "black"
                ),
                radius      = 8,
                popup       = ~paste(
                    "<b>", library_branch_name, "</b><br>",
                    "Status: ", open_status, "</b><br>",
                    "Hours: ", opening_hours
                ),
                label       = ~library_branch_name
            )
    })
}