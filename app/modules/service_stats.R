# Service Statistics Module
# Displays library service statistics with city filtering

library(ggplot2)
library(DT)

# The chart title for the city picked in the stats tab ("all" or none: the whole country)
stats_chart_title <- function(city) {
  if (!is.null(city) && city != "all") sprintf(txt$stats_title_city, city) else txt$stats_title_all
}

# The service table with its column headings
stats_table <- function(counts) {
  names(counts)[names(counts) == "service_name"] <- txt$stats_col_service
  names(counts)[names(counts) == "library_count"] <- txt$stats_col_count
  counts
}

# UI function for service statistics
service_stats_ui <- function(id) {
  ns <- NS(id)

  tagList(
    fluidRow(
      column(
        12,
        h3(txt$stats_heading),
        p(txt$stats_intro),
        br(),
        selectInput(
          ns("stats_city"),
          txt$stats_city_label,
          choices = c(setNames("all", txt$all_cities)),
          selected = "all"
        )
      )
    ),
    fluidRow(
      column(
        12,
        h4(txt$stats_top_heading),
        plotOutput(ns("service_chart"), height = "500px")
      )
    ),
    br(),
    fluidRow(
      column(
        12,
        h4(txt$stats_all_heading),
        DT::dataTableOutput(ns("service_table"))
      )
    )
  )
}

# Server function for service statistics
service_stats_server <- function(id, library_services, libraries, dark_mode) {
  moduleServer(id, function(input, output, session) {

    # Populate city choices
    observe({
      libs <- libraries()
      req(libs)

      cities <- stringr::str_sort(unique(libs$city_name), locale = "fi")

      updateSelectInput(
        session,
        "stats_city",
        choices = c(setNames("all", txt$all_cities), cities),
        selected = "all"
      )
    })

    # Calculate service counts (filtered by city)
    service_counts <- reactive({
      services_data <- library_services()
      libs <- libraries()
      req(services_data, libs)

      # Filter library_services by selected city
      if (!is.null(input$stats_city) && input$stats_city != "all") {
        # Get library IDs in the selected city
        lib_ids_in_city <- libs %>%
          filter(city_name == input$stats_city) %>%
          pull(id)

        filtered_services <- services_data %>%
          filter(library_id %in% lib_ids_in_city)
      } else {
        filtered_services <- services_data
      }

      # Count services
      filtered_services %>%
        count(service_name, name = "library_count") %>%
        arrange(desc(library_count))
    })

    # Bar chart of top 15 services
    output$service_chart <- renderPlot({
      data <- service_counts() %>%
        head(15)  # Top 15 services

      req(nrow(data) > 0)

      is_dark    <- isTRUE(dark_mode())
      # Match Bootstrap 5 body text: dark-mode fg (#FFFFFF) vs light-mode body (#212529)
      text_color <- if (is_dark) "#FFFFFF" else "#212529"
      bg_color   <- if (is_dark) "#191414" else "#FFFFFF"

      ggplot(data, aes(x = reorder(service_name, library_count),
                       y = library_count)) +
        geom_col(fill = "#C1272D") +
        geom_text(
          aes(label = library_count),
          hjust = -0.2, size = 3.5, color = text_color
        ) +
        coord_flip() +
        scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
        labs(
          title = stats_chart_title(input$stats_city),
          x = NULL,
          y = NULL
        ) +
        theme_minimal() +
        theme(
          text             = element_text(color = text_color),
          axis.text.y      = element_text(size = 11, color = text_color),
          axis.text.x      = element_blank(),
          axis.ticks       = element_blank(),
          panel.grid       = element_blank(),
          plot.background  = element_rect(fill = bg_color, color = NA),
          panel.background = element_rect(fill = bg_color, color = NA),
          plot.title       = element_text(size = 14, face = "bold",
                                          color = text_color)
        )
      # bg = "transparent" lets the ggplot plot.background fill (set above) show through
    }, bg = "transparent")

    # Data table with all services. server = FALSE: the whole table (about 250
    # rows) goes to the page once and paging, sorting and searching happen in the
    # browser. With the default (server = TRUE) every page, sort and search is a
    # request to a URL that belongs to the Shiny session, which answers 404 once
    # the session has ended (a page left open for an hour, or across a deploy),
    # and DataTables then shows an "Ajax error" alert.
    output$service_table <- DT::renderDataTable({
      service_counts() %>%
        stats_table()
    }, server = FALSE, options = list(
      pageLength = 20,
      searching = TRUE,
      ordering = TRUE,
      lengthMenu = c(10, 20, 50, 100)
    ))
  })
}
