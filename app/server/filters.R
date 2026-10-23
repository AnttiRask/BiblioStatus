# Filter dropdowns: startup city, user changes, clear buttons, "Show on Map".
# Evaluated inside server() (see server_parts in server.R), so it shares the
# session's reactive state, input, output and session.
# State: selection, startup_city*.
#
# The rules (which choices each dropdown offers, what a change does to the other
# dropdowns, the notices) are in www/filter_logic.R, which has no Shiny in it and
# is tested on its own. This file only connects them to the inputs:
#   * `selection()` is the one place that says what the dropdowns hold. The
#     browser's input$* values are only read as "the user changed this".
#   * Every change goes through apply_filter_change(); the result is pushed to
#     the dropdowns by push_dropdowns(), which sends only what changed.
#   * When the browser echoes a value we just sent, apply_filter_change() sees
#     nothing changed and nothing happens, so there is no cascade and no race.
#   * The map follows selection() directly (see map.R): there is no "Show on Map".

dropdown_ids <- c(city = "city_filter", service = "service_filter", library = "library_search")

# What each dropdown was last sent (choices and selected value), so unchanged
# lists are not sent again. The browser's own picks are noted here too.
sent_to_browser <- new.env()

push_dropdowns <- function(sel = selection()) {
  libs <- library_data()
  svcs <- library_services_data()
  if (is.null(libs) || is.null(svcs)) return(invisible())  # sent when the data arrives

  opts <- filter_options(libs, svcs, sel)
  lists <- list(
    city    = as_choices(opts$cities, txt$all_cities),
    service = as_choices(opts$services, txt$all_services),
    library = as_choices(opts$libraries, txt$all_libraries, counts = FALSE)
  )

  for (field in names(lists)) {
    id <- dropdown_ids[[field]]
    now <- list(choices = lists[[field]], selected = sel[[field]])
    if (identical(sent_to_browser[[id]], now)) next
    sent_to_browser[[id]] <- now

    if (field == "library") {
      updateSelectizeInput(session, id, choices = now$choices,
        selected = now$selected, server = TRUE)
    } else {
      updateSelectInput(session, id, choices = now$choices, selected = now$selected)
    }
  }
  invisible()
}

# The user picked `value` in one dropdown (`field` is "city", "service" or
# "library"; "" means cleared). Returns TRUE if the selection changed.
# `from_dropdown` is FALSE when the change did not come from the dropdown itself
# (the x buttons): the browser's dropdown still shows the old value then, so it
# must be sent the new one.
handle_user_change <- function(field, value, from_dropdown = TRUE) {
  libs <- library_data()
  svcs <- library_services_data()
  req(libs, svcs)
  value <- if (is.null(value)) "" else value

  result <- apply_filter_change(libs, svcs, selection(), field, value)
  id <- dropdown_ids[[field]]

  if (!result$changed) {
    # Either the browser echoing what we sent (nothing to do), or a value that
    # isn't offered: send ours back so the dropdown shows what we hold.
    if (!identical(value, selection()[[field]])) sent_to_browser[[id]] <- NULL
    push_dropdowns()
    return(invisible(FALSE))
  }

  if (from_dropdown && !is.null(sent_to_browser[[id]])) {
    sent_to_browser[[id]]$selected <- value  # the browser already shows it
  }
  commit_selection_change(result)
  invisible(TRUE)
}

# Make a changed result of apply_filter_change() / jump_to_library() the
# selection, and bring everything that depends on it along
commit_selection_change <- function(result) {
  city_changed <- !identical(result$sel$city, selection()$city)
  service_changed <- !identical(result$sel$service, selection()$service)
  selection(result$sel)

  # The nearest-libraries result belongs to the city shown and to the service it
  # was searched with: clear it when either changes (press Find Nearest again)
  if (city_changed || service_changed) {
    nearest_libraries(NULL)
    user_location(NULL)
  }
  if (city_changed) selected_library(NULL)
  push_dropdowns(result$sel)
  if (!is.null(result$notice)) showNotification(result$notice, type = "message", duration = 6)
}

# The search box offers every library, once the data has arrived
observeEvent(library_data(), {
  updateSelectizeInput(session, "library_finder", choices = finder_choices(library_data()), server = FALSE)
}, once = TRUE)

# Picking a result jumps to that library (its city, and the library), through the
# same selection as the dropdowns, and the box empties again: it is a way to get
# to a library, not a fourth filter with a state of its own
observeEvent(input$library_finder, {
  id <- input$library_finder
  req(!is.null(id), nzchar(id))
  libs <- library_data()
  svcs <- library_services_data()
  req(libs, svcs)
  result <- jump_to_library(libs, svcs, selection(), id)
  if (result$changed) commit_selection_change(result)
  updateSelectizeInput(session, "library_finder", selected = "")
}, ignoreInit = TRUE, ignoreNULL = FALSE)

# Fill the dropdowns when the data arrives (and, after a reconnect, show the
# selection that was seeded from the browser's values)
observe({
  req(library_data(), library_services_data())
  isolate(push_dropdowns())
})

# The startup city (nearest library's city, or Helsinki) becomes the city
# selection, which also draws the first map. The data may not have arrived yet when
# the fallback fires; the populate observer above then shows the selection.
#
# It only applies when no city has been chosen yet. The startup events are sent
# again after a reconnect (and the 9 s fallback can fire after the user has
# already picked a city); in both cases the selection already has a city, and
# overwriting it would move the map away from what the dropdowns show.
set_city_from_startup <- function(city) {
  startup_city_set(TRUE)
  if (nzchar(selection()$city)) return(invisible())
  libs <- library_data()
  svcs <- library_services_data()

  if (!is.null(libs) && !is.null(svcs)) {
    result <- apply_filter_change(libs, svcs, selection(), "city", city)
    selection(result$sel)
    if (!is.null(result$notice)) showNotification(result$notice, type = "message", duration = 6)
  } else {
    selection(modifyList(selection(), list(city = city)))
  }
  push_dropdowns()
}

# Startup geolocation: set city to nearest library's city
observeEvent(input$startup_location, {
  req(!startup_city_set())
  all_libs <- library_data()
  req(all_libs)

  loc <- input$startup_location
  nearest_city <- all_libs %>%
    mutate(dist = (lat - loc$lat)^2 + (lon - loc$lon)^2) %>%
    arrange(dist) %>%
    slice(1) %>%
    pull(city_name)

  startup_city(nearest_city)
  set_city_from_startup(nearest_city)
})

# Startup geolocation failed or timed out: default to Helsinki
observeEvent(input$startup_geolocation_failed, {
  req(!startup_city_set())
  set_city_from_startup("Helsinki")
})

observeEvent(input$startup_geolocation_timeout, {
  req(!startup_city_set())
  set_city_from_startup("Helsinki")
})

# The three dropdowns. ignoreInit: a first value is either empty (normal page
# load) or the browser re-sending its values after a reconnect, which the
# seeding observer in server.R takes care of. ignoreNULL = FALSE: clearing a
# dropdown ("") must fire too.
observeEvent(input$city_filter,    handle_user_change("city", input$city_filter),
  ignoreInit = TRUE, ignoreNULL = FALSE)
observeEvent(input$service_filter, handle_user_change("service", input$service_filter),
  ignoreInit = TRUE, ignoreNULL = FALSE)
observeEvent(input$library_search, handle_user_change("library", input$library_search),
  ignoreInit = TRUE, ignoreNULL = FALSE)

# The x buttons clear one filter through the same path as clearing by hand
# (the dropdown itself isn't touched, so the cleared value is sent to it).
observeEvent(input$clear_library, handle_user_change("library", "", from_dropdown = FALSE))
observeEvent(input$clear_service, handle_user_change("service", "", from_dropdown = FALSE))

# "Reset filters": back to the state after startup, the startup city and nothing else
observeEvent(input$reset_filters, {
  selection(list(city = startup_city(), service = "", library = ""))
  nearest_libraries(NULL)
  user_location(NULL)
  push_dropdowns()
})

# The library detail panel follows the library selection (a marker click can
# still show another library's details without changing the selection)
show_selected_library <- function() {
  lib_id <- selection()$library
  libs <- library_data()
  if (nzchar(lib_id) && !is.null(libs)) {
    row <- libs %>% filter(id_text(id) == lib_id)
    selected_library(if (nrow(row) > 0) row else NULL)
  } else {
    selected_library(NULL)
  }
}

# Only when the selection changes. Not when library_data() changes: that happens
# every time a status changes (see data.R) and would close the details of a
# library opened by a marker click.
observeEvent(selection()$library, show_selected_library())

# And once when the data first arrives, for a library that a link or a reconnect
# selected before there was any data
observeEvent(library_data(), {
  if (nzchar(selection()$library)) show_selected_library()
}, once = TRUE)
