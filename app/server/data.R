# Data loading.
# Evaluated inside server() (see server_parts in server.R), so it shares the
# session's reactive state, input, output and session. State: library_data, library_services_data, all_library_schedules, library_base, schedule_rows, status_clock.

# The data is loaded once per page; the statuses are recomputed every minute from
# the loaded schedule rows and the clock (see compute_library_statuses()).
library_base <- reactiveVal(NULL)    # the libraries, without a status
schedule_rows <- reactiveVal(NULL)   # the schedule rows loaded: today and tomorrow
status_clock <- reactiveVal(NULL)    # the "HH:MM" the statuses were last computed for

# Recompute the statuses for now. library_data() (what the map, the filters and
# Find Nearest read) is only replaced when something changed, so a minute
# without a change doesn't redraw the map.
refresh_statuses <- function() {
  libraries <- isolate(library_base())
  rows <- isolate(schedule_rows())
  if (is.null(libraries) || is.null(rows)) return(invisible())

  now <- helsinki_time_now()
  today <- format(helsinki_today(), "%Y-%m-%d")

  data <- compute_library_statuses(libraries, rows, today, now)
  if (!identical(data, isolate(library_data()))) library_data(data)

  # Today's rows for the detail panel and the "no data" notice
  day_rows <- todays_schedules(rows, today, now)
  if (!identical(day_rows, isolate(all_library_schedules()))) all_library_schedules(day_rows)

  status_clock(now)
  invisible()
}

# Data fetching and processing
refresh_data <- function() {
  library_base(fetch_libraries())
  schedule_rows(fetch_schedules())
  library_services_data(fetch_library_services())
  refresh_statuses()
}

# Every minute, a little after the minute changes
observe({
  invalidateLater(ms_to_next_minute())
  refresh_statuses()
})

# A library whose details are open keeps showing its current status
observeEvent(library_data(), {
  shown <- isolate(selected_library())
  if (is.null(shown)) return()
  updated <- library_data() %>% filter(id == shown$id)
  if (nrow(updated) == 1 && !identical(updated, shown)) selected_library(updated)
})

# Initial fetch and manual refresh
observeEvent(
  input$refresh,
  {
    refresh_data()
  },
  ignoreNULL = FALSE
)
