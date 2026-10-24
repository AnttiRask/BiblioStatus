# Sidebar panels: geolocation error, nearest libraries, selected library details.
# Evaluated inside server() (see server_parts in server.R), so it shares the
# session's reactive state, input, output and session. State: nearest_libraries, selected_library, all_library_schedules, library_services_data.

# Error display UI
output$geolocation_error_ui <- renderUI({
  req(input$geolocation_error)
  div(class = "alert alert-danger", role = "alert",
    style = "margin: 10px 0; padding: 10px;",
    icon("exclamation-triangle"), " ", input$geolocation_error)
})

# Nearest libraries display UI
output$nearest_libraries_ui <- renderUI({
  nearest <- nearest_libraries()
  req(nearest)
  req(nrow(nearest) > 0)

  tagList(
    h4(
      # says which service it was for; the list is cleared when the service changes
      if (nzchar(selection()$service)) sprintf(txt$nearest_heading_service, selection()$service) else txt$nearest_heading,
      style = "color: var(--brand-accent);"
    ),
    lapply(1:nrow(nearest), function(i) {
      lib <- nearest[i, ]
      maps_url <- sprintf(
        "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f",
        lib$lat, lib$lon
      )
      div(
        style = "margin-bottom: 15px; padding: 10px; border-left: 3px solid var(--brand-accent); background-color: rgba(193, 39, 45, 0.05);",
        tags$b(lib$library_branch_name),
        br(),
        tags$small(lib$city_name),
        br(),
        tags$small(style = "color: var(--brand-accent); font-weight: bold;",
          lib$distance_display),
        br(),
        tags$a(
          href = maps_url,
          target = "_blank",
          class = "btn btn-sm btn-directions mt-2",
          icon("location-arrow"), txt$get_directions
        )
      )
    })
  )
})

# Sidebar panel with library info
output$library_services <- renderUI({
  selected <- selected_library()
  req(selected)
  schedules <- all_library_schedules()

  {
    maps_url <- sprintf(
      "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f",
      selected$lat, selected$lon
    )

    # The time the statuses were last computed for (changes every minute, so the
    # "now" mark in the day's schedule moves)
    now <- status_clock()
    req(now)

    # Format all schedule periods
    schedule_html <- if (!is.null(schedules)) {
      format_schedule_periods(selected$id, schedules, now)
    } else {
      paste0("<p>", htmltools::htmlEscape(txt$no_schedule), "</p>")
    }

    tagList(
      h4(selected$library_branch_name),
      p(selected$library_address),

      # Current status (prominently displayed)
      tags$b(txt$current_status),
      p(selected$open_status),

      # Today's full schedule
      tags$b(txt$todays_schedule),
      HTML(schedule_html),
      br(),

      # Contact information (phone)
      if (!is.na(selected$library_phone)) {
        tagList(
          tags$a(
            href = paste0("tel:", selected$library_phone),
            icon("phone"), " ", selected$library_phone,
            style = "display: block; margin-bottom: 8px; color: var(--brand-accent); text-decoration: none;"
          )
        )
      },

      # Contact information (email)
      if (!is.na(selected$library_email)) {
        tagList(
          tags$a(
            href = paste0("mailto:", selected$library_email),
            icon("envelope"), " ", selected$library_email,
            style = "display: block; margin-bottom: 8px; color: var(--brand-accent); text-decoration: none;"
          )
        )
      },
      br(),

      # Get Directions button
      tags$a(
        href = maps_url,
        target = "_blank",
        class = "btn btn-sm btn-directions mb-3",
        icon("location-arrow"), txt$get_directions
      ),

      # Services
      tags$b(txt$services_heading),
      {
        services <- library_services_data()
        if (!is.null(services)) {
          lib_services <- services %>%
            filter(library_id == selected$id) %>%
            pull(service_name) %>%
            sort()

          if (length(lib_services) > 0) {
            # Display as visual badges
            div(
              class = "service-badges mt-2",
              lapply(lib_services, function(svc) {
                span(
                  svc,
                  class = "badge",
                  style = "display: inline-block; background-color: #e3f2fd; color: #1976d2;
                           padding: 6px 12px; margin: 3px; border-radius: 6px;
                           font-size: 13px; font-weight: 500; line-height: 1.5;"
                )
              })
            )
          } else {
            p(txt$no_services, style = "color: #888; font-style: italic; margin-top: 8px;")
          }
        }
      }
    )
  }
})

# A note above the map when the data is not the live data (the nightly backup,
# or older data while Turso is down), when it could not be loaded, or when
# there is no schedule data for today at all (the nightly update has not run
# yet): every library would otherwise look like it just has an unknown status.
output$data_notice <- renderUI({
  state <- data_state() %||% list(source = "turso")
  schedules <- all_library_schedules()
  notice <- data_notice_for(state, schedules_empty = !is.null(schedules) && nrow(schedules) == 0)
  if (!is.null(notice)) {
    div(class = paste("alert mx-3 my-2", notice$class), role = "status", notice$text)
  }
})

# One line under the filters: how many libraries the map shows and for what
output$filter_summary <- renderText({
  libs <- libraries_on_map()
  sel <- selection()
  count <- nrow(libs)
  library_name <- if (nzchar(sel$library)) library_data()$library_branch_name[id_text(library_data()$id) == sel$library] else ""
  # An empty city means "All Cities" once the starting city has been decided
  city <- if (nzchar(sel$city)) sel$city else if (startup_city_set()) txt$all_cities else ""
  parts <- c(
    sprintf(if (count == 1) txt$summary_one else txt$summary_many, count),
    city, sel$service, library_name
  )
  paste(parts[nzchar(parts)], collapse = " \u00b7 ")
})
