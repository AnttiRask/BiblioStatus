# Load required libraries
library(leaflet)
library(shiny)
library(shinyjs)

ui <- fluidPage(
  # Enable JavaScript interactivity
  useShinyjs(),
  # Meta and styles/scripts
  tags$head(
    # Responsive design
    tags$meta(
      name = "viewport",
      content = "width=device-width, initial-scale=1"
    ),
    # tags$script(
    #   '
    #     Shiny.addCustomMessageHandler("checkMobile", function(message) {
    #     var isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
    #     Shiny.setInputValue("is_mobile", isMobile);
    #     });
    #     '
    # ),
    # Custom styles
    tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
  ),
  # Detect if device is mobile, and store it in input$is_mobile
  tags$script(HTML(
    "
      Shiny.addCustomMessageHandler('checkMobile', function(message) {
        var isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
        Shiny.setInputValue('is_mobile', isMobile, {priority: 'event'});
      });
      $(document).on('shiny:sessioninitialized', function() {
        Shiny.setInputValue('is_mobile', /iPhone|iPad|iPod|Android/i.test(navigator.userAgent), {priority: 'event'});
      });
    "
  )),
  # App title
  titlePanel("BiblioStatus - Which Finnish Libraries Are Open Right Now?"),

  # Layout: Sidebar + Main panel
  sidebarLayout(
    sidebarPanel(
      class = "sidebar-panel",
      selectInput(
        inputId = "city_filter",
        label = "Select City/Municipality:",
        choices = NULL
      ),
      checkboxInput(
        inputId = "dark_mode",
        label = span("Dark mode", class = "dark-mode-label"),
        value = FALSE
      ),
      br(),
      # Shows details of selected library (desktop only)
      uiOutput("library_services")
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
