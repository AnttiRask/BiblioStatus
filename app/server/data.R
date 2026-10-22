# Data loading.
# Evaluated inside server() (see server_parts in server.R), so it shares the
# session's reactive state, input, output and session. State: library_data, library_services_data, all_library_schedules.

# Data fetching and processing
refresh_data <- function() {
  libraries <- fetch_libraries()
  schedules <- fetch_schedules()
  services <- fetch_library_services()

  now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")

  # Add computed fields to schedules
  schedules <- schedules %>%
    mutate(
      is_open_now = from <= now & to >= now,
      open_status = case_when(
        status_label == "Closed for the whole day" ~
          "Closed for the whole day",
        is_open_now & status_label == "Open" ~ "Open",
        is_open_now & status_label == "Self-service" ~ "Self-service",
        is_open_now & status_label == "Temporarily closed" ~
          "Temporarily closed",
        TRUE ~ "Closed"
      )
    )

  # Store ALL schedules for detail panel
  all_library_schedules(schedules)

  # Create map display version (one status per library for marker colors)
  map_display <- schedules %>%
    group_by(library_id) %>%
    arrange(desc(is_open_now), desc(to)) %>%
    slice(1) %>%
    ungroup() %>%
    mutate(
      opening_hours = if_else(
        is_open_now,
        paste0(from, " - ", to),
        NA_character_
      )
    )

  # Join libraries with map display data
  data <- libraries %>%
    left_join(map_display, by = join_by(id == library_id))

  library_data(data)
  library_services_data(services)
}

# Initial fetch and manual refresh
observeEvent(
  input$refresh,
  {
    refresh_data()
  },
  ignoreNULL = FALSE
)
