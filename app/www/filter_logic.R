# Filter logic for the city / service / library dropdowns, with no Shiny in it
# so it can be tested on its own.
#
# A selection is list(city = "", service = "", library = ""); "" means "all".
# The library is a library id written as text.
#
# The rules (so a selection is never silently thrown away and the lists never
# offer a choice that gives an empty map):
#   * The city list is always complete: neither the service nor a picked
#     library narrows it.
#   * The service list depends on the city only (a picked library does not
#     narrow it).
#   * The library list depends on the city and the service.
#   * Picking a library also sets the city to the library's city.
#   * Picking a city that the selected service is not offered in clears the
#     service, and picking a city or service that the picked library does not
#     match clears the library. Each says so in a notice.

# libs: one row per library (id, library_branch_name, city_name, ...)
# services: library_id, service_name

empty_selection <- function() list(city = "", service = "", library = "")

# Make sure all three fields exist and are single strings ("" for NULL / NA)
normalize_selection <- function(sel) {
  one <- function(x) {
    if (is.null(x) || length(x) == 0 || is.na(x[[1]])) "" else as.character(x[[1]])
  }
  list(city = one(sel$city), service = one(sel$service), library = one(sel$library))
}

# Library ids as text without scientific notation (as.character(1e5) is "1e+05")
id_text <- function(id) format(id, scientific = FALSE, trim = TRUE)

# The libraries that match the selection. Fields named in `ignore` are skipped,
# which is how each dropdown's own list is worked out.
filter_libraries <- function(libs, services, sel, ignore = character()) {
  sel <- normalize_selection(sel)

  if (!"city" %in% ignore && nzchar(sel$city)) {
    libs <- libs |> filter(city_name == sel$city)
  }
  if (!"service" %in% ignore && nzchar(sel$service)) {
    with_service <- services |> filter(service_name == sel$service) |> pull(library_id)
    libs <- libs |> filter(id %in% with_service)
  }
  if (!"library" %in% ignore && nzchar(sel$library)) {
    libs <- libs |> filter(id_text(id) == sel$library)
  }
  libs
}

# What each dropdown should offer for a selection: tibbles with value, label
# and n (the number of libraries behind the choice). "All ..." is not included.
filter_options <- function(libs, services, sel) {
  sel <- normalize_selection(sel)
  by_finnish <- function(tbl, col) tbl[stringr::str_order(tbl[[col]], locale = "fi"), ]

  city_libs <- filter_libraries(libs, services, sel, ignore = c("city", "service", "library"))
  cities <- city_libs |>
    count(city_name, name = "n") |>
    mutate(value = city_name, label = sprintf("%s (%d)", city_name, n)) |>
    by_finnish("value") |>
    select(value, label, n)

  service_libs <- filter_libraries(libs, services, sel, ignore = c("service", "library"))
  service_choices <- services |>
    filter(library_id %in% service_libs$id) |>
    distinct(library_id, service_name) |>
    count(service_name, name = "n") |>
    mutate(value = service_name, label = sprintf("%s (%d)", service_name, n)) |>
    by_finnish("value") |>
    select(value, label, n)

  library_choices <- filter_libraries(libs, services, sel, ignore = "library") |>
    transmute(value = id_text(id), label = library_branch_name, n = 1L) |>
    by_finnish("label")

  list(cities = cities, services = service_choices, libraries = library_choices)
}

# A named vector for selectInput(): names are what the user reads
as_choices <- function(options, all_label, counts = TRUE) {
  labels <- if (counts) options$label else sub(" \\([0-9]+\\)$", "", options$label)
  c(setNames("", all_label), setNames(options$value, labels))
}

# Apply one change made by the user (`changed` is "city", "service" or "library",
# `value` is "" to clear it) and return
#   sel     the new selection
#   notice  text to tell the user, or NULL
#   changed FALSE when nothing happened: the value was already selected (the
#           browser echoing our own update) or is not one of the offered choices
apply_filter_change <- function(libs, services, sel, changed, value, msgs = txt) {
  sel <- normalize_selection(sel)
  value <- normalize_selection(list(city = value))$city
  stopifnot(changed %in% c("city", "service", "library"))

  unchanged <- list(sel = sel, notice = NULL, changed = FALSE)
  if (identical(sel[[changed]], value)) return(unchanged)

  facet <- c(city = "cities", service = "services", library = "libraries")[[changed]]
  if (nzchar(value) && !value %in% filter_options(libs, services, sel)[[facet]]$value) {
    return(unchanged)
  }

  sel[[changed]] <- value

  # A library implies its city
  if (changed == "library" && nzchar(value)) {
    sel$city <- libs |> filter(id_text(id) == value) |> pull(city_name) |> first()
  }

  notices <- character()

  # A city or service the picked library doesn't match clears the library
  if (changed %in% c("city", "service") && nzchar(value) && nzchar(sel$library)) {
    still_matches <- nrow(filter_libraries(libs, services, sel, ignore = character())) > 0
    if (!still_matches) {
      notices <- c(notices, if (changed == "city") {
        sprintf(msgs$notice_library_not_in_city, value)
      } else {
        sprintf(msgs$notice_library_no_service, value)
      })
      sel$library <- ""
    }
  }

  # A city the selected service isn't offered in clears the service
  if (changed == "city" && nzchar(value) && nzchar(sel$service)) {
    offered_here <- services |>
      filter(library_id %in% libs$id[libs$city_name == value]) |>
      pull(service_name)
    if (!sel$service %in% offered_here) {
      notices <- c(notices, sprintf(msgs$notice_service_not_in_city, value))
      sel$service <- ""
    }
  }

  notice <- if (length(notices)) paste(notices, collapse = ". ") else NULL
  list(sel = sel, notice = notice, changed = TRUE)
}

# ---------------------------------------------------------------------------
# The selection in the page address (?city=Espoo&service=Sauna&library=123), so
# a link restores a selection and a reconnected page starts from the same one.
# ---------------------------------------------------------------------------

filter_fields <- c("city", "service", "library")

# The address query for a selection; "?" when nothing is selected. Values are
# percent-encoded (UTF-8), so city and service names with ä, ö or spaces work.
selection_to_query <- function(sel) {
  sel <- normalize_selection(sel)
  parts <- vapply(
    filter_fields[nzchar(unlist(sel[filter_fields]))],
    function(field) paste0(field, "=", utils::URLencode(sel[[field]], reserved = TRUE)),
    character(1)
  )
  paste0("?", paste(parts, collapse = "&"))
}

# A valid selection from an address query (a list like shiny::parseQueryString()
# returns). The fields are applied in the order city, service, library through
# the same rules as the dropdowns, on top of `base`: a value that isn't offered
# (a made-up city, a service the city doesn't have, a library elsewhere) is
# ignored instead of producing an empty map. `ignored` names those fields.
selection_from_query <- function(libs, services, query, base = empty_selection()) {
  sel <- normalize_selection(base)
  requested <- normalize_selection(query[filter_fields])

  for (field in filter_fields) {
    if (!nzchar(requested[[field]])) next
    result <- apply_filter_change(libs, services, sel, field, requested[[field]])
    if (result$changed) sel <- result$sel
  }

  asked <- filter_fields[nzchar(unlist(requested[filter_fields]))]
  ignored <- asked[!vapply(asked, function(field) identical(sel[[field]], requested[[field]]), logical(1))]
  list(sel = sel, ignored = ignored)
}

