# Service Statistics Module
# Displays library service statistics with city filtering

library(ggplot2)
library(DT)

# UI function for service statistics
service_stats_ui <- function(id) {
  ns <- NS(id)

  tagList(
    fluidRow(
      column(
        12,
        h3("Library Service Statistics"),
        p("Explore which services are offered by Finnish libraries across different cities"),
        br(),
        selectInput(
          ns("stats_city"),
          "Filter by City:",
          choices = NULL,  # Populated in server
          selected = NULL
        )
      )
    ),
    fluidRow(
      column(
        12,
        h4("Top 15 Most Common Services"),
        plotOutput(ns("service_chart"), height = "500px")
      )
    ),
    br(),
    fluidRow(
      column(
        12,
        h4("All Services"),
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

      cities <- libs %>%
        pull(city_name) %>%
        unique() %>%
        sort()

      updateSelectInput(
        session,
        "stats_city",
        choices = c("All Cities" = "", cities),
        selected = ""
      )
    })

    # Calculate service counts (filtered by city)
    service_counts <- reactive({
      services_data <- library_services()
      libs <- libraries()
      req(services_data, libs)

      # Filter library_services by selected city
      if (!is.null(input$stats_city) && input$stats_city != "") {
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
      bg_color   <- if (is_dark) "#191414" else "#FFFFFF"
      text_color <- if (is_dark) "#FFFFFF" else "#1a1a1a"

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
          title = if (!is.null(input$stats_city) && input$stats_city != "") {
            paste("Most Common Services in", input$stats_city)
          } else {
            "Most Common Library Services (All Cities)"
          },
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
    }, bg = "transparent")

    # Data table with all services
    output$service_table <- DT::renderDataTable({
      service_counts() %>%
        rename(
          "Service Name" = service_name,
          "Libraries Offering" = library_count
        )
    }, options = list(
      pageLength = 20,
      searching = TRUE,
      ordering = TRUE,
      lengthMenu = c(10, 20, 50, 100)
    ))
  })
}
