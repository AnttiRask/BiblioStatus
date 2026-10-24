# The selection in the page address: a link restores a selection, and the
# address follows the dropdowns. The rules are in www/filter_logic.R
# (selection_from_query / selection_to_query).
# Evaluated inside server() (see server_parts in server.R).
# State: selection, startup_city_set.

# TRUE once the address has been read (or there was nothing to read); until then
# the address is not written, so the incoming link isn't overwritten
url_ready <- reactiveVal(FALSE)

# Read the address once, when the data has loaded (a link's values are checked
# against it). A link with a city (or with an empty `city=`, which is "All
# Cities") decides the starting city, so the map doesn't wait for the location.
observeEvent(library_data(), {
  libs <- library_data()
  svcs <- library_services_data()
  req(libs, svcs)

  search <- url_search_of(session)
  if (is.null(search)) search <- ""
  query <- shiny::parseQueryString(search)
  all_cities <- query_asks_for_all_cities(query)
  if (any(nzchar(unlist(query[filter_fields]))) || all_cities) {
    result <- selection_from_query(libs, svcs, query, base = selection())
    selection(result$sel)
    if (nzchar(result$sel$city) || all_cities) startup_city_set(TRUE)
    push_dropdowns(result$sel)
    if (length(result$ignored) > 0) showNotification(txt$url_ignored, type = "warning", duration = 8)
  }
  url_ready(TRUE)
}, once = TRUE)

# Keep the address in step with the selection. "replace": no history entry per
# change, so the back button leaves the page as it should.
observe({
  req(url_ready())
  # Once the starting city is decided, an empty city means "All Cities"
  updateQueryString(selection_to_query(selection(), all_cities = startup_city_set()), mode = "replace", session = session)
})
