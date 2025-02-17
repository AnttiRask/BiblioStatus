library(leaflet)
library(shiny)
library(shinyjs)

ui <- fluidPage(
    useShinyjs(),
    tags$head(
        tags$style(HTML("#map { visibility: hidden; }"))
    ),
    titlePanel("BiblioStatus - Which Libraries Are Open Right Now?"),
    sidebarLayout(
        sidebarPanel(
            selectInput(
                inputId  = "city_filter",
                label    = "Select City:",
                choices  = NULL # Empty for now, will be updated later
            ),
            actionButton("refresh", "Refresh Opening Statuses")
        ),
        mainPanel(
            div(
                id = "loading-spinner",
                "Loading data, please wait...",
                style = "text-align: center; font-size: 20px; padding: 20px;"
            ),
            leafletOutput("map", height = 600)
        )
    )
)
