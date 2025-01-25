library(leaflet)
library(shiny)
library(shinyjs)

ui <- fluidPage(
    useShinyjs(),
    tags$head(
        tags$style(HTML("#map { visibility: hidden; }"))
    ),
    titlePanel("BiblioStatus - Which (Helsinki) Libraries Are Open Right Now?"),
    sidebarLayout(
        sidebarPanel(
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
