# Load required libraries
library(bslib)
library(leaflet)
library(shiny)
library(shinyjs)

# Load module UI functions
source("modules/service_stats.R", local = TRUE)

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

        // Watch for bslib dark mode changes (data-bs-theme attribute on <html>)
        var darkModeObserver = new MutationObserver(function(mutations) {
          mutations.forEach(function(mutation) {
            if (mutation.attributeName === 'data-bs-theme') {
              var isDark = document.documentElement.getAttribute('data-bs-theme') === 'dark';
              Shiny.setInputValue('is_dark_mode', isDark, {priority: 'event'});
            }
          });
        });
        darkModeObserver.observe(document.documentElement, { attributes: true });

        $(document).on('shiny:sessioninitialized', function() {
          Shiny.setInputValue('is_mobile', /iPhone|iPad|iPod|Android/i.test(navigator.userAgent), {priority: 'event'});

          // Report initial dark mode state
          var isDark = document.documentElement.getAttribute('data-bs-theme') === 'dark';
          Shiny.setInputValue('is_dark_mode', isDark, {priority: 'event'});

          // Request geolocation on startup to determine nearest city
          if (navigator.geolocation) {
            navigator.geolocation.getCurrentPosition(
              function(position) {
                Shiny.setInputValue('startup_location', {
                  lat: position.coords.latitude,
                  lon: position.coords.longitude
                }, {priority: 'event'});
              },
              function(error) {
                Shiny.setInputValue('startup_geolocation_failed', true, {priority: 'event'});
              },
              { enableHighAccuracy: false, timeout: 8000, maximumAge: 600000 }
            );
          } else {
            Shiny.setInputValue('startup_geolocation_failed', true, {priority: 'event'});
          }

          // Fallback: after 9 seconds, if startup location still not received, use Helsinki
          setTimeout(function() {
            Shiny.setInputValue('startup_geolocation_timeout', true, {priority: 'event'});
          }, 9000);
        });

        // Geolocation handler for finding nearest library (Find Nearest button)
        Shiny.addCustomMessageHandler('requestGeolocation', function(message) {
          if (!navigator.geolocation) {
            Shiny.setInputValue('geolocation_error',
              'Geolocation is not supported by your browser',
              {priority: 'event'});
            return;
          }

          Shiny.setInputValue('geolocation_loading', true, {priority: 'event'});

          navigator.geolocation.getCurrentPosition(
            function(position) {
              Shiny.setInputValue('user_location', {
                lat: position.coords.latitude,
                lon: position.coords.longitude
              }, {priority: 'event'});
              Shiny.setInputValue('geolocation_loading', false, {priority: 'event'});
            },
            function(error) {
              var errorMsg = error.code === 1 ?
                'Please enable location permissions to find nearby libraries' :
                'Unable to get your location. Please try again.';
              Shiny.setInputValue('geolocation_error', errorMsg, {priority: 'event'});
              Shiny.setInputValue('geolocation_loading', false, {priority: 'event'});
            },
            { enableHighAccuracy: true, timeout: 10000, maximumAge: 300000 }
          );
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
  # Library Map fills viewport; Service Statistics scrolls naturally
  fillable = c("library_map" = TRUE, "service_stats" = FALSE),

  # Main map view tab
  nav_panel(
    title = "Library Map",
    value = "library_map",

    layout_sidebar(
      sidebar = sidebar(
        width = 400,
        div(
          div(class = "d-flex justify-content-between align-items-baseline mb-1",
            tags$label(`for` = "city_filter", class = "control-label mb-0",
              "Select City/Municipality:"),
            actionButton("clear_city", label = HTML("&times;"),
              class = "btn btn-link p-0 clear-select-btn",
              title = "Clear city selection")
          ),
          selectInput(inputId = "city_filter", label = NULL, choices = NULL)
        ),
        div(
          div(class = "d-flex justify-content-between align-items-baseline mb-1",
            tags$label(`for` = "library_search", class = "control-label mb-0",
              "Select Library:"),
            actionButton("clear_library", label = HTML("&times;"),
              class = "btn btn-link p-0 clear-select-btn",
              title = "Clear library selection")
          ),
          selectizeInput(inputId = "library_search", label = NULL, choices = NULL,
            options = list(placeholder = "All Libraries"))
        ),
        div(
          div(class = "d-flex justify-content-between align-items-baseline mb-1",
            tags$label(`for` = "service_filter", class = "control-label mb-0",
              "Select Service:"),
            actionButton("clear_service", label = HTML("&times;"),
              class = "btn btn-link p-0 clear-select-btn",
              title = "Clear service selection")
          ),
          selectInput(inputId = "service_filter", label = NULL, choices = NULL,
            selected = NULL)
        ),
        actionButton(
          inputId = "find_nearest",
          label = "Find Nearest Open Library",
          icon = icon("location-dot"),
          class = "btn-primary w-100"
        ),
        conditionalPanel(
          condition = "input.geolocation_loading",
          div(class = "text-center", style = "color: #C1272D; margin: 10px 0;",
            icon("spinner", class = "fa-spin"), " Getting your location...")
        ),
        uiOutput("geolocation_error_ui"),
        uiOutput("nearest_libraries_ui"),
        # Shows details of selected library (desktop only)
        uiOutput("library_services"),
        create_app_footer("bibliostatus")
      ),

      # Main content
      h4(
        "Which Finnish Libraries Are Open Right Now?",
        style = "margin: 12px 16px 4px; font-weight: 600;"
      ),
      div(
        id = "loading-spinner",
        "Loading data, please wait...",
        class = "loading-text",
        style = paste(
          "position: absolute;",
          "top: 50%; left: 50%;",
          "transform: translate(-50%, -50%);",
          "z-index: 1000;"
        )
      ),
      leafletOutput("map", height = "calc(100vh - 56px)"),
      div(style = "height: 40px;")
    )
  ),

  # Service Statistics tab
  nav_panel(
    title = "Service Statistics",
    value = "service_stats",

    div(
      class = "container mt-4",
      service_stats_ui("stats"),
      create_app_footer("bibliostatus")
    )
  ),

  # Dark mode toggle (top-right in navbar)
  nav_spacer(),
  nav_item(input_dark_mode(id = "dark_mode", mode = "light"))
)
