# Filter dropdowns: startup city, cascades, clear buttons, "Show on Map".
# Evaluated inside server() (see server_parts in server.R), so it shares the
# session's reactive state, input, output and session. State: committed_*, pending_*, startup_city*.

# Rebuild the service dropdown's choices to only services offered by the
# given set of library ids (a single selected library, or every library in
# a city), re-affirming the current selection if it's still valid among
# those choices or resetting it to "All Services" otherwise. Returns the
# new selection so callers can keep pending_service() in sync.
update_service_choices_for_libraries <- function(lib_ids, all_svcs, current_service) {
  svc_choices <- stringr::str_sort(
    unique(all_svcs %>% filter(library_id %in% lib_ids) %>% pull(service_name)),
    locale = "fi"
  )
  still_valid <- !is.null(current_service) && current_service %in% svc_choices
  new_service <- if (still_valid) current_service else ""
  updateSelectInput(session, "service_filter",
    choices = c(setNames("", txt$all_services), svc_choices),
    selected = new_service)
  new_service
}

# Populate all filter selectors on data load
observe({
  all_libs <- library_data()
  all_svcs <- library_services_data()
  req(all_libs, all_svcs)

  city_choices <- stringr::str_sort(unique(all_libs$city_name), locale = "fi")
  lib_choices  <- all_libs %>%
    arrange(library_branch_name) %>%
    { setNames(as.character(.$id), .$library_branch_name) }
  svc_choices  <- stringr::str_sort(unique(all_svcs$service_name), locale = "fi")

  isolate({
    updateSelectInput(session, "city_filter",
      choices = c(setNames("", txt$all_cities), city_choices), selected = "")
    updateSelectizeInput(session, "library_search",
      choices = c(setNames("", txt$all_libraries), lib_choices), server = TRUE)
    updateSelectInput(session, "service_filter",
      choices = c(setNames("", txt$all_services), svc_choices), selected = "")
  })
})

# Startup geolocation: set city to nearest library's city
observeEvent(input$startup_location, {
  req(!startup_city_set())
  all_libs <- library_data()
  req(all_libs)
  startup_city_set(TRUE)

  loc <- input$startup_location
  nearest_city <- all_libs %>%
    mutate(dist = (lat - loc$lat)^2 + (lon - loc$lon)^2) %>%
    arrange(dist) %>%
    slice(1) %>%
    pull(city_name)

  startup_city(nearest_city)
  updateSelectInput(session, "city_filter", selected = nearest_city)
  committed_city(nearest_city)  # triggers initial map render (no browser round-trip needed)
})

# Startup geolocation failed or timed out: default to Helsinki
observeEvent(input$startup_geolocation_failed, {
  req(!startup_city_set())
  startup_city_set(TRUE)
  updateSelectInput(session, "city_filter", selected = "Helsinki")
  committed_city("Helsinki")  # triggers initial map render
})

observeEvent(input$startup_geolocation_timeout, {
  req(!startup_city_set())
  startup_city_set(TRUE)
  updateSelectInput(session, "city_filter", selected = "Helsinki")
  committed_city("Helsinki")  # triggers initial map render
})

# Library selectize: selecting a library auto-updates the city dropdown and
# narrows the service dropdown to just that library's own services (city
# cascade only narrows service to the whole city's aggregate). Clearing the
# library (selected == "") widens service back out to the current city's
# scope instead, since there's no more specific library to narrow it to.
observeEvent(input$library_search, {
  all_libs <- library_data()
  all_svcs <- library_services_data()
  req(all_libs, all_svcs)

  if (input$library_search == "") {
    current_city <- isolate(input$city_filter)
    city_lib_ids <- if (!is.null(current_city) && current_city != "") {
      all_libs %>% filter(city_name == current_city) %>% pull(id)
    } else {
      all_libs$id
    }
    new_service <- update_service_choices_for_libraries(
      city_lib_ids, all_svcs, isolate(input$service_filter))
    pending_service(new_service)
    return()
  }

  selected_lib <- all_libs %>% filter(id == as.numeric(input$library_search))
  req(nrow(selected_lib) > 0)

  updateSelectInput(session, "city_filter",
    selected = selected_lib$city_name[1])

  new_service <- update_service_choices_for_libraries(
    selected_lib$id, all_svcs, isolate(input$service_filter))
  pending_service(new_service)
}, ignoreInit = TRUE, ignoreNULL = FALSE)

# Cascading: city → update library choices, and service choices+selection.
# City itself is NOT updated by the other two — that bidirectional dependency
# caused stale-read race conditions where one cascade re-injected an outdated
# value from another input (e.g. old service coming back after × clear).
# City choices stay as "all cities" (set by the populate observer on data load).
observeEvent(input$city_filter, {
  all_libs <- library_data()
  all_svcs <- library_services_data()
  req(all_libs, all_svcs)

  current_service <- isolate(input$service_filter)

  city_lib_ids <- if (!is.null(input$city_filter) && input$city_filter != "") {
    all_libs %>% filter(city_name == input$city_filter) %>% pull(id)
  } else {
    all_libs$id
  }

  # The service that will still be selected after this city change: the current
  # one if the new city offers it, otherwise none (it is reset to "All Services"
  # further down). The library list must use this one: filtering by a service
  # the new city doesn't have left the library dropdown empty.
  services_in_city <- all_svcs %>% filter(library_id %in% city_lib_ids) %>% pull(service_name)
  effective_service <- if (!is.null(current_service) && current_service %in% services_in_city) {
    current_service
  } else {
    ""
  }

  # Library choices = intersection of city + service filters
  filtered_ids <- city_lib_ids
  if (effective_service != "") {
    svc_ids <- all_svcs %>% filter(service_name == effective_service) %>% pull(library_id)
    filtered_ids <- intersect(filtered_ids, svc_ids)
  }

  lib_choices <- all_libs %>%
    filter(id %in% filtered_ids) %>%
    arrange(library_branch_name) %>%
    { setNames(as.character(.$id), .$library_branch_name) }

  # This city change may be the side effect of picking a specific library
  # (library_search's own observer sets city_filter to that library's city).
  # If pending_library() still refers to a library that's valid in this new
  # city, keep it selected and keep the library-scoped service choices
  # library_search's observer already set - don't reset either back out to
  # "no library" / city-wide service, which would immediately undo that pick.
  still_picked_lib_id <- pending_library()
  library_pick_still_valid <- !is.null(still_picked_lib_id) &&
    still_picked_lib_id != "" && as.numeric(still_picked_lib_id) %in% city_lib_ids

  updateSelectizeInput(session, "library_search",
    choices = c(setNames("", txt$all_libraries), lib_choices), server = TRUE,
    selected = if (library_pick_still_valid) still_picked_lib_id else "")
  if (!library_pick_still_valid) {
    pending_library("")
  }

  # Service choices = only services offered by libraries in the selected city
  # (matches the library dropdown's own city scoping, so a service that has
  # zero results in this city can't even be picked). Re-affirm the current
  # selection if it's still valid there, otherwise reset it to "All Services".
  # Skipped when a library pick is still valid above - that already scoped
  # service choices to just that library, which is narrower/more correct.
  if (!library_pick_still_valid) {
    new_service <- update_service_choices_for_libraries(city_lib_ids, all_svcs, current_service)
    pending_service(new_service)
  }

  # Reset state when city changes
  nearest_libraries(NULL)
  user_location(NULL)
  selected_library(NULL)
}, ignoreInit = TRUE)

# Cascading: service → update library choices only.
# Service choices stay as "all services" (set by the populate observer on data load).
# ignoreNULL = FALSE: must fire when service is cleared to "" (isTruthy("") = FALSE).
observeEvent(input$service_filter, {
  pending_service(input$service_filter)

  all_libs <- library_data()
  all_svcs <- library_services_data()
  req(all_libs, all_svcs)

  current_city <- isolate(input$city_filter)

  # Library choices = intersection of service + city filters
  filtered_ids <- all_libs$id
  if (!is.null(input$service_filter) && input$service_filter != "") {
    svc_ids <- all_svcs %>% filter(service_name == input$service_filter) %>% pull(library_id)
    filtered_ids <- intersect(filtered_ids, svc_ids)
  }
  if (!is.null(current_city) && current_city != "") {
    city_ids <- all_libs %>% filter(city_name == current_city) %>% pull(id)
    filtered_ids <- intersect(filtered_ids, city_ids)
  }

  lib_choices <- all_libs %>%
    filter(id %in% filtered_ids) %>%
    arrange(library_branch_name) %>%
    { setNames(as.character(.$id), .$library_branch_name) }

  updateSelectizeInput(session, "library_search",
    choices = c(setNames("", txt$all_libraries), lib_choices), server = TRUE, selected = "")
}, ignoreInit = TRUE, ignoreNULL = FALSE)

# Mirror library_search into pending_library on every real change (selecting
# a library, or the cascades above resetting it to "" on city/service change).
observeEvent(input$library_search, {
  pending_library(input$library_search)
}, ignoreInit = TRUE, ignoreNULL = FALSE)

# Individual clear buttons — each clears one filter; cascades handle downstream updates.
# Also write through to committed_* AND pending_* so the map updates immediately
# (without requiring "Show on Map") and so a subsequent "Show on Map" click commits
# the clear even if the browser round-trip for input$service_filter/library_search
# (triggered by updateSelectInput/updateSelectizeInput below) hasn't landed yet.
observeEvent(input$clear_library, {
  updateSelectizeInput(session, "library_search", selected = "")
  pending_library("")

  # Widen the service dropdown back out to the current city's scope: it may
  # have been narrowed to just this library's own services, and there's no
  # more specific library left to scope it to.
  all_libs <- library_data()
  all_svcs <- library_services_data()
  req(all_libs, all_svcs)
  current_city <- isolate(input$city_filter)
  city_lib_ids <- if (!is.null(current_city) && current_city != "") {
    all_libs %>% filter(city_name == current_city) %>% pull(id)
  } else {
    all_libs$id
  }
  new_service <- update_service_choices_for_libraries(
    city_lib_ids, all_svcs, isolate(input$service_filter))
  pending_service(new_service)

  selected_library(NULL)
  committed_library("")
})

observeEvent(input$clear_service, {
  updateSelectInput(session, "service_filter", selected = "")
  pending_service("")

  # Also clear the library filter: its narrowed choice list (and any
  # selection within it) was a side effect of the service filter, not an
  # independent choice, so there's no valid library selection left to keep.
  # Rebuild the choice list too (not just the selection) - scoped to the
  # current city only, since the service constraint is now gone - otherwise
  # the dropdown's options stay stuck at the pre-clear, service-filtered set
  # even though the map and the selected value both reset correctly.
  all_libs <- library_data()
  req(all_libs)
  current_city <- isolate(input$city_filter)
  city_lib_ids <- if (!is.null(current_city) && current_city != "") {
    all_libs %>% filter(city_name == current_city) %>% pull(id)
  } else {
    all_libs$id
  }
  lib_choices <- all_libs %>%
    filter(id %in% city_lib_ids) %>%
    arrange(library_branch_name) %>%
    { setNames(as.character(.$id), .$library_branch_name) }
  updateSelectizeInput(session, "library_search",
    choices = c(setNames("", txt$all_libraries), lib_choices), server = TRUE, selected = "")
  pending_library("")
  committed_library("")
  selected_library(NULL)
  committed_service("")
})

# "Show on Map" button: commit current dropdown state and re-render the map.
# Uses pending_service()/pending_library() rather than input$service_filter/
# input$library_search directly — see the pending_* reactiveVal declarations
# above for why reading input$* here can see a stale, pre-clear value.
# Also activates the library detail sidebar when a specific library is selected.
observeEvent(input$apply_filters, {
  committed_city(input$city_filter)
  committed_service(pending_service())
  committed_library(pending_library())

  lib_id <- pending_library()
  if (!is.null(lib_id) && lib_id != "") {
    selected_lib <- library_data() %>% filter(id == as.numeric(lib_id))
    selected_library(if (nrow(selected_lib) > 0) selected_lib else NULL)
  } else {
    selected_library(NULL)
  }
})
