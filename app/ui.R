# Load required libraries
library(leaflet)
library(shiny)
library(shinyjs)

ui <- fluidPage(
    useShinyjs(),
    tags$head(
      tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
      tags$script(
        '
        Shiny.addCustomMessageHandler("checkMobile", function(message) {
        var isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
        Shiny.setInputValue("is_mobile", isMobile);
        });
        '
      ),
      tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
      tags$script(HTML("
        Shiny.addCustomMessageHandler('bindPopupCloseEvent', function(message) {
          var map = window.LeafletMap;
          if (map) {
            map.on('popupclose', function(e) {
              Shiny.setInputValue('popup_closed', true, {priority: 'event'});
            });
          }
        });
      ")),
    ),
    tags$script(HTML("
      Shiny.addCustomMessageHandler('checkMobile', function(message) {
        var isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
        Shiny.setInputValue('is_mobile', isMobile, {priority: 'event'});
      });
      $(document).on('shiny:sessioninitialized', function() {
        Shiny.setInputValue('is_mobile', /iPhone|iPad|iPod|Android/i.test(navigator.userAgent), {priority: 'event'});
      });
    ")),
    titlePanel("BiblioStatus - Which Finnish Libraries Are Open Right Now?"),
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
                # Light mode is default
                value = FALSE
            ),
            br(),
            # Dynamic info for selected library
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
