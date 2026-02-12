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
                p(class = "text-muted mb-2", "youcanbeapiRate apps:"),
                div(
                    class = "d-flex justify-content-center gap-3 flex-wrap",
                    if(current_app != "trackteller")
                        a(href = "https://trackteller.youcanbeapirate.com", "TrackTeller"),
                    if(current_app != "tuneteller")
                        a(href = "https://tuneteller.youcanbeapirate.com", "TuneTeller"),
                    if(current_app != "bibliostatus")
                        a(href = "https://bibliostatus.youcanbeapirate.com", "BiblioStatus"),
                    if(current_app != "gallery")
                        a(href = "https://galleryoftheday.youcanbeapirate.com", "Gallery of the Day")
                )
            ),
            div(
                class = "footer-credit",
                p(
                    "Created by ",
                    a(href = "https://anttirask.github.io", "Antti Rask"),
                    " | ",
                    a(href = "https://youcanbeapirate.com", "youcanbeapirate.com")
                )
            )
        )
    )
}

ui <- page_sidebar(
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

  # Enable JavaScript interactivity
  useShinyjs(),

  # Meta and styles/scripts
  header = tags$head(
    tags$link(rel = "shortcut icon", type = "image/png", href = "favicon.png"),
    # Responsive design
    tags$meta(
      name = "viewport",
      content = "width=device-width, initial-scale=1"
    ),
    # Custom styles
    tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
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
    ))
  ),

  # App title
  title = "BiblioStatus - Which Finnish Libraries Are Open Right Now?",

  # Sidebar
  sidebar = sidebar(
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

  # Footer
  create_app_footer("bibliostatus")
)
