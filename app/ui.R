# Load required libraries
library(leaflet)
library(shiny)
library(shinyjs)

ui <- fluidPage(
  useShinyjs(),
  tags$head(
    tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
  ),
  titlePanel("BiblioStatus - Which Finnish Libraries Are Open Right Now?"),
  sidebarLayout(
    sidebarPanel(
      selectInput(
        inputId = "city_filter",
        label = "Select City/Municipality:",
        choices = NULL
      )
      # ,
      # checkboxInput(
      #     inputId = "dark_mode",
      #     label = span("Dark mode", class = "dark-mode-label"),
      #     # Light mode is default
      #     value = FALSE
      # )
    ),
    mainPanel(
      div(
        id = "loading-spinner",
        "Loading data, please wait...",
        class = "loading-text"
      ),
      leafletOutput("map", height = "85vh")
    )
  )
)
