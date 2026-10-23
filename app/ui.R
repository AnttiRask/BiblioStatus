# UI. Packages, helpers and settings come from global.R.

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
                    lapply(
                        Filter(function(app) app$id != current_app, footer_apps),
                        function(app) a(href = app$url, app$name)
                    )
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
  theme = app_theme(),

  header = tags$head(
    tags$title(txt$app_title),
    tags$link(rel = "icon", type = "image/png", href = "favicon.png"),
    # Client-side settings (geolocation timings) for app.js, then the script
    tags$script(HTML(sprintf(
      "window.BIBLIO_CONFIG = %s;",
      jsonlite::toJSON(geo_config, auto_unbox = TRUE)
    ))),
    tags$script(src = asset("app.js")),
    # Enable JavaScript interactivity
    useShinyjs(),
    # Custom CSS
    includeCSS("www/styles.css")
  ),

  # App title
  title = txt$app_title,
  id = "main_navbar",
  # Library Map fills viewport; Service Statistics scrolls naturally
  fillable = c("library_map" = TRUE, "service_stats" = FALSE),

  # Main map view tab
  nav_panel(
    title = txt$tab_map,
    value = "library_map",

    layout_sidebar(
      sidebar = sidebar(
        width = 400,
        selectizeInput(
          inputId = "library_finder",
          label = txt$finder_label,
          choices = NULL,
          options = list(placeholder = txt$finder_placeholder)
        ),
        selectInput(
          inputId = "city_filter",
          label = txt$city_label,
          choices = NULL
        ),
        div(
          div(class = "d-flex justify-content-between align-items-baseline mb-1",
            tags$label(`for` = "library_search", class = "control-label mb-0",
              txt$library_label),
            actionButton("clear_library", label = HTML("&times;"),
              class = "btn btn-link p-0 clear-select-btn",
              title = txt$clear_library,
              `aria-label` = txt$clear_library)
          ),
          selectizeInput(inputId = "library_search", label = NULL, choices = NULL,
            options = list(placeholder = txt$library_placeholder))
        ),
        div(
          div(class = "d-flex justify-content-between align-items-baseline mb-1",
            tags$label(`for` = "service_filter", class = "control-label mb-0",
              txt$service_label),
            actionButton("clear_service", label = HTML("&times;"),
              class = "btn btn-link p-0 clear-select-btn",
              title = txt$clear_service,
              `aria-label` = txt$clear_service)
          ),
          selectInput(inputId = "service_filter", label = NULL, choices = NULL,
            selected = NULL)
        ),
        div(class = "filter-summary d-flex justify-content-between align-items-baseline mb-2",
          textOutput("filter_summary", inline = TRUE),
          actionLink("reset_filters", txt$reset_filters)
        ),
        actionButton(
          inputId = "find_nearest",
          label = txt$find_nearest,
          icon = icon("location-dot"),
          class = "btn-primary w-100"
        ),
        conditionalPanel(
          condition = "input.geolocation_loading",
          div(class = "text-center", style = "color: var(--brand-accent); margin: 10px 0;",
            icon("spinner", class = "fa-spin"), txt$getting_location)
        ),
        uiOutput("geolocation_error_ui"),
        uiOutput("nearest_libraries_ui"),
        # Shows details of selected library (desktop only)
        uiOutput("library_services"),
        create_app_footer("bibliostatus")
      ),

      # Main content
      h4(
        txt$heading,
        style = "margin: 12px 16px 4px; font-weight: 600;"
      ),
      # Shown only when there is no schedule data for today
      uiOutput("data_notice"),
      div(
        id = "loading-spinner",
        txt$loading,
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
    title = txt$tab_stats,
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
