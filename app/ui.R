# Load required libraries
library(leaflet)
library(shiny)
library(shinyjs)

ui <- fluidPage(
  useShinyjs(),
  tags$head(
    tags$style(HTML("#map { visibility: hidden; }"))
  ),
  titlePanel("BiblioStatus - Which Finnish Libraries Are Open Right Now?"),
  sidebarLayout(
    sidebarPanel(
      selectInput(
        inputId = "city_filter",
        label = "Select City/Municipality:",
        choices = NULL
      ),
      actionButton("refresh", "Refresh Opening Status")
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
