# Load required libraries
library(bslib)
library(leaflet)
library(shiny)
library(shinyjs)

# Shared footer component for cross-linking between apps
create_app_footer <- function(current_app = "") {
    tags$footer(
        class = "app-footer mt-5 py-4 border-top",
        div(
            class = "container text-center",
            div(
                class = "footer-apps mb-3",
                div(
                    class = "d-flex justify-content-center gap-3 flex-wrap",
                    if(current_app != "bibliostatus")
                        a(href = "https://bibliostatus.youcanbeapirate.com", "BiblioStatus"),
                    if(current_app != "gallery")
                        a(href = "https://galleryoftheday.youcanbeapirate.com", "Gallery of the Day"),
                    if(current_app != "trackteller")
                        a(href = "https://trackteller.youcanbeapirate.com", "TrackTeller"),
                    if(current_app != "tuneteller")
                        a(href = "https://tuneteller.youcanbeapirate.com", "TuneTeller")
                )
            ),
            div(
                class = "footer-credit",
                p(
                    "Created by ",
                    a(href = "https://www.linkedin.com/in/AnttiRask/", "Antti Rask"),
                    " | ",
                    a(href = "https://youcanbeapirate.com", "youcanbeapirate.com")
                )
            )
        )
    )
}

ui <- page_navbar(
  theme = bs_theme(
    version = 5,
    bg = "#191414",
    fg = "#FFFFFF",
    primary = "#C1272D",
    base_font = font_link(
      family = "Gotham",
      href = "https://fonts.cdnfonts.com/css/gotham-6"
    )
  ),

  header = tags$head(
    tags$title("BiblioStatus"),
    tags$link(rel = "icon", type = "image/png", href = "favicon.png"),
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
    # Enable JavaScript interactivity
    useShinyjs(),
    # Custom CSS
    includeCSS("www/styles.css")
  ),

  # App title
  title = "BiblioStatus",
  id = "main_navbar",

  # Main map view
  nav_panel(
    title = "Library Map",
    value = "library_map",

    layout_sidebar(
      sidebar = sidebar(
        width = 350,
        h3("BiblioStatus"),
        p("Which Finnish Libraries Are Open Right Now?"),
        br(),
        selectInput(
          inputId = "city_filter",
          label = "Select City/Municipality:",
          choices = NULL
        ),
        input_dark_mode(id = "dark_mode", mode = "light"),
        br(),
        # Shows details of selected library (desktop only)
        uiOutput("library_services")
      ),

      # Main content
      div(
        id = "loading-spinner",
        "Loading data, please wait...",
        class = "loading-text"
      ),
      leafletOutput("map", height = "85vh"),
      div(style = "height: 40px;")
    )
  ),

  # Footer
  footer = create_app_footer("bibliostatus")
)
