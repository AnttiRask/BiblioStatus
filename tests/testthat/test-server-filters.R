# Tests for the filter dropdowns as wired into the server (app/server/filters.R):
# the selection, the map following it, the x buttons, Reset, the detail panel and
# the notices. The rules themselves are tested without Shiny in
# test-filter-logic.R.
#
# Uses a small fixture data set (not the real Turso/SQLite fetch) so tests are
# fast, deterministic, and don't depend on network or database availability.

fixture_libraries <- data.frame(
  id = c(1, 2, 3),
  library_branch_name = c("Alpha Library", "Beta Library", "Gamma Library"),
  lat = c(60.1, 60.2, 61.5),
  lon = c(24.9, 24.8, 23.7),
  city_name = c("Helsinki", "Helsinki", "Tampere"),
  library_url = NA_character_,
  library_phone = NA_character_,
  library_email = NA_character_,
  library_address = "Test address",
  from = "09:00",
  to = "20:00",
  status_label = "Open",
  is_open_now = TRUE,
  open_status = "Open",
  opening_hours = "09:00 - 20:00",
  stringsAsFactors = FALSE
)

fixture_services <- data.frame(
  library_id = c(1, 2),
  service_name = c("Printing", "Printing"),
  stringsAsFactors = FALSE
)

# Distinct per-library services (unlike fixture_services above, where both
# Helsinki libraries offer the same one) - needed to test that selecting a
# library narrows the service dropdown to just its own services, not the
# whole city's aggregate.
fixture_services_distinct <- data.frame(
  library_id = c(1, 1, 2),
  service_name = c("Printing", "Scanning", "Yoga"),
  stringsAsFactors = FALSE
)

# The server's own startup observer (observeEvent(input$refresh, ...,
# ignoreNULL = FALSE)) fires on session init and calls refresh_data(), which
# hits the real Turso/SQLite fetch. Flush that first, then overwrite with
# fixture data so tests are deterministic and don't depend on real data.
# Must be called from inside testServer()'s eval context (not extracted into
# a helper taking `environment()`, which does not give access to the
# testServer-local reactiveVals via $).
# The server loads its data when a session starts, so without these every test
# in this file would read the real database (Turso where the credentials exist,
# the SQLite backup in CI), and what the page says about the data source would
# depend on where the tests run. Replace the fetch functions for the whole file;
# tests that need other data replace them again and restore these.
local({
  names_replaced <- c("fetch_libraries", "fetch_schedules", "fetch_library_services")
  was_global <- vapply(names_replaced, exists, logical(1), envir = globalenv(), inherits = FALSE)
  originals <- mget(names_replaced, envir = globalenv(), inherits = TRUE)
  assign("fetch_libraries", function() {
    fixture_libraries[, c("id", "library_branch_name", "lat", "lon", "city_name",
      "library_url", "library_phone", "library_email", "library_address")]
  }, envir = globalenv())
  assign("fetch_schedules", function() {
    data.frame(library_id = numeric(), date = character(), from = character(),
      to = character(), status_label = character(), stringsAsFactors = FALSE)
  }, envir = globalenv())
  assign("fetch_library_services", function() fixture_services, envir = globalenv())
  withr::defer(for (name in names_replaced) {
    if (was_global[[name]]) assign(name, originals[[name]], envir = globalenv()) else rm(list = name, envir = globalenv())
  }, envir = testthat::teardown_env())
})

seed_fixture_data_code <- quote({
  session$flushReact()
  library_data(fixture_libraries)
  library_services_data(fixture_services)
  startup_city_set(TRUE)
})

ids_on_map <- quote(sort(libraries_on_map()$id))

test_that("the map follows the dropdowns as soon as one changes", {
  testServer(server, {
    eval(seed_fixture_data_code)
    expect_equal(eval(ids_on_map), c(1, 2, 3))

    session$setInputs(city_filter = "Helsinki")
    expect_equal(eval(ids_on_map), c(1, 2))

    session$setInputs(service_filter = "Printing")
    session$setInputs(library_search = "1")
    expect_equal(eval(ids_on_map), 1)
  })
})

test_that("the service filter alone narrows the map", {
  one_service_each <- data.frame(
    library_id = c(1, 2, 3),
    service_name = c("Printing", "Yoga", "Printing"),
    stringsAsFactors = FALSE
  )
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(one_service_each)
    startup_city_set(TRUE)

    session$setInputs(service_filter = "Printing")
    expect_equal(eval(ids_on_map), c(1, 3))        # across cities

    session$setInputs(city_filter = "Helsinki")
    expect_equal(eval(ids_on_map), 1)              # service and city together

    session$setInputs(service_filter = "")
    expect_equal(eval(ids_on_map), c(1, 2))
  })
})

# The x buttons must widen the map right away even though testServer() (like
# a slow browser) never echoes the cleared value back to input$*: the map reads
# selection(), not the inputs.
test_that("the x buttons widen the map immediately, without waiting for the browser's echo", {
  testServer(server, {
    eval(seed_fixture_data_code)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    session$setInputs(library_search = "1")
    expect_equal(eval(ids_on_map), 1)

    session$setInputs(clear_library = 1)
    expect_equal(selection()$library, "")
    expect_equal(eval(ids_on_map), c(1, 2))

    session$setInputs(clear_service = 1)
    expect_equal(selection()$service, "")
    expect_equal(eval(ids_on_map), c(1, 2))
  })
})

# Under the old rules a library only existed because the service had narrowed
# the dropdown to it, so clearing the service cleared the library too. Now the
# library is an independent choice, so clearing the service leaves it alone.
test_that("clearing the service filter leaves the library selection alone", {
  testServer(server, {
    eval(seed_fixture_data_code)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    session$setInputs(library_search = "1")
    session$setInputs(clear_service = 1)
    expect_equal(selection(), list(city = "Helsinki", service = "", library = "1"))
    expect_equal(eval(ids_on_map), 1)
  })
})

test_that("the library details follow the library selection", {
  testServer(server, {
    eval(seed_fixture_data_code)
    expect_null(selected_library())

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    expect_equal(selected_library()$id, 1)

    session$setInputs(library_search = "2")
    expect_equal(selected_library()$id, 2)

    session$setInputs(clear_library = 1)
    expect_null(selected_library())

    session$setInputs(library_search = "1")
    session$setInputs(city_filter = "Tampere")       # library 1 isn't in Tampere
    expect_null(selected_library())
  })
})

test_that("Reset filters returns to the startup city and nothing else", {
  testServer(server, {
    eval(seed_fixture_data_code)
    startup_city("Tampere")

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    session$setInputs(library_search = "1")
    expect_equal(selection(), list(city = "Helsinki", service = "Printing", library = "1"))

    session$setInputs(reset_filters = 1)
    expect_equal(selection(), list(city = "Tampere", service = "", library = ""))
    expect_equal(eval(ids_on_map), 3)
    expect_null(selected_library())
  })
})

test_that("the summary line says how many libraries are shown and for what", {
  testServer(server, {
    eval(seed_fixture_data_code)
    session$flushReact()   # render the output with the fixture data, not the startup load
    # no city chosen, and the starting city is decided: that is "All Cities"
    expect_equal(output$filter_summary, "3 libraries \u00b7 All Cities")

    session$setInputs(city_filter = "Helsinki")
    expect_equal(output$filter_summary, "2 libraries \u00b7 Helsinki")

    session$setInputs(service_filter = "Printing")
    session$setInputs(library_search = "1")
    expect_equal(output$filter_summary, "1 library \u00b7 Helsinki \u00b7 Printing \u00b7 Alpha Library")
  })
})

# A library never narrows the service list now (see www/filter_logic.R), and
# the library list only offers libraries that match the city and the service.
# Uses fixture_services_distinct (library 1: Printing + Scanning, library 2:
# Yoga only) so the two libraries' service sets differ.
test_that("a library the selected service doesn't match isn't offered, so picking it is refused", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(fixture_services_distinct)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Yoga")
    expect_equal(selection()$service, "Yoga")

    # Library 1 doesn't offer Yoga (only library 2 does): the selection stays
    session$setInputs(library_search = "1")
    expect_equal(selection(), list(city = "Helsinki", service = "Yoga", library = ""))
  })
})

test_that("selecting a library keeps a compatible service selection", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(fixture_services_distinct)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    expect_equal(selection()$service, "Printing")

    # Library 1 does offer Printing
    session$setInputs(library_search = "1")
    expect_equal(selection(), list(city = "Helsinki", service = "Printing", library = "1"))
  })
})

test_that("picking a library sets its city, and clearing the library keeps the service", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(fixture_services_distinct)
    startup_city_set(TRUE)

    session$setInputs(library_search = "3")
    expect_equal(selection()$city, "Tampere")

    session$setInputs(city_filter = "Helsinki")      # Gamma isn't in Helsinki: cleared
    expect_equal(selection(), list(city = "Helsinki", service = "", library = ""))

    session$setInputs(service_filter = "Printing")
    session$setInputs(library_search = "1")
    session$setInputs(clear_library = 1)
    expect_equal(selection(), list(city = "Helsinki", service = "Printing", library = ""))
  })
})

# NOTE: the service-label-resync behavior (city_filter observer calling
# updateSelectInput(session, "service_filter", ...) to reset or re-affirm the
# displayed value) is NOT covered here. shiny::testServer() does not simulate
# the client-side JS round-trip that updateSelectInput()/updateSelectizeInput()
# depend on to feed a changed value back into input$x — so any assertion on
# input$service_filter after such an update call would pass or fail based on
# a testServer limitation, not the actual app behavior. That behavior was
# verified against the real running app with a Playwright browser script
# during Plan 1's implementation (see full-fix-plan.md, Plan 1's "Outcome").
# A real regression test for it would need shinytest2, which drives an actual
# browser, rather than testServer().

# Regression: bslib::input_dark_mode() reports "dark"/"light" (a string), but the
# map code tested isTRUE(input$dark_mode), which is never TRUE for a string, so
# the map's tiles and marker colours never went dark (introduced when
# `if (input$dark_mode)` was wrapped in isTRUE() to stop it erroring).
test_that("is_dark follows bslib's string value and also accepts a logical", {
  testServer(server, {
    eval(seed_fixture_data_code)

    expect_false(is_dark())                   # nothing reported yet
    session$setInputs(dark_mode = "dark")
    expect_true(is_dark())
    session$setInputs(dark_mode = "light")
    expect_false(is_dark())
    session$setInputs(dark_mode = TRUE)       # older bslib
    expect_true(is_dark())
    session$setInputs(dark_mode = FALSE)
    expect_false(is_dark())
  })
})

# The map is rendered once; later changes go through leafletProxy() as calls of
# refresh_map(). These tests record those calls (the real function still runs).
record_map_updates <- function(env = parent.frame()) {
  calls <- new.env()
  calls$refresh <- list()
  calls$renders <- 0
  real_refresh <- get("refresh_map", envir = globalenv())
  real_options <- get("map_options", envir = globalenv())
  assign("refresh_map", function(map, data, dark = FALSE, mobile = FALSE, fit = TRUE) {
    calls$refresh[[length(calls$refresh) + 1]] <- list(
      proxy = inherits(map, "leaflet_proxy"), n = nrow(data), dark = dark, fit = fit
    )
    real_refresh(map, data, dark, mobile, fit)
  }, envir = globalenv())
  assign("map_options", function(mobile = FALSE) {
    calls$renders <- calls$renders + 1      # called once per render of the base map
    real_options(mobile)
  }, envir = globalenv())
  withr::defer({
    assign("refresh_map", real_refresh, envir = globalenv())
    assign("map_options", real_options, envir = globalenv())
  }, envir = env)
  calls
}

test_that("the first map uses the theme at that moment: dark tiles and the dark marker palette", {
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(dark_mode = "dark", is_mobile = FALSE)
    session$flushReact()
    dark_map <- as.character(output$map)
    expect_match(dark_map, "World_Dark_Gray_Base", fixed = TRUE)
    expect_match(dark_map, "World_Dark_Gray_Reference", fixed = TRUE)
    expect_false(grepl("World_Light_Gray", dark_map, fixed = TRUE))
    expect_match(dark_map, dark_colors$Open, fixed = TRUE)
  })

  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(dark_mode = "light", is_mobile = FALSE)
    session$flushReact()
    light_map <- as.character(output$map)
    expect_match(light_map, "World_Light_Gray_Base", fixed = TRUE)
    expect_false(grepl("World_Dark_Gray", light_map, fixed = TRUE))
    expect_match(light_map, light_colors$Open, fixed = TRUE)
  })
})

test_that("a filter change updates the map through the proxy and moves the view, without rebuilding the map", {
  calls <- record_map_updates()

  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(dark_mode = "light", is_mobile = FALSE)
    session$flushReact()
    invisible(output$map)
    expect_equal(calls$renders, 1)
    expect_false(calls$refresh[[length(calls$refresh)]]$proxy)   # the render itself
    before <- length(calls$refresh)

    session$setInputs(city_filter = "Helsinki")
    session$flushReact()
    update <- calls$refresh[[length(calls$refresh)]]
    expect_gt(length(calls$refresh), before)
    expect_true(update$proxy)
    expect_equal(update$n, 2)          # Alpha and Beta
    expect_true(update$fit)            # a different set of libraries: move the view
    expect_equal(calls$renders, 1)     # the base map was not rendered again
  })
})

test_that("a theme change alone swaps tiles and colours but keeps the user's view", {
  calls <- record_map_updates()

  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(dark_mode = "light", is_mobile = FALSE)
    session$flushReact()
    invisible(output$map)

    session$setInputs(dark_mode = "dark")
    session$flushReact()
    update <- calls$refresh[[length(calls$refresh)]]
    expect_true(update$proxy)
    expect_true(update$dark)
    expect_false(update$fit)           # same libraries: the view stays
    expect_equal(calls$renders, 1)
  })
})

# After a reconnect (session$allowReconnect("force")) the browser re-sends all
# the dropdown values as the new session's FIRST values, in one go. testServer()
# does the same when the very first setInputs() call carries them all (so no
# session$flushReact() before it, unlike seed_fixture_data_code, which would use
# up the first flush).
test_that("a reconnect restores the selection, so the map agrees with the dropdowns", {
  testServer(server, {
    session$setInputs(
      city_filter = "Tampere", library_search = "3", service_filter = "Printing"
    )

    expect_equal(selection(), list(city = "Tampere", service = "Printing", library = "3"))
  })
})

test_that("a reconnect with only a city restores that city", {
  testServer(server, {
    session$setInputs(city_filter = "Helsinki", library_search = "", service_filter = "")

    expect_equal(selection(), list(city = "Helsinki", service = "", library = ""))
  })
})

# The startup inputs are sent again after a reconnect (seen in a real browser:
# the new session seeded Espoo + a service from the dropdowns and then, 1.3 s
# later, startup moved the city to Helsinki, so the map no longer matched the
# dropdowns). The startup city must only apply when no city is chosen yet.
test_that("the startup city doesn't overwrite a city that is already selected", {
  testServer(server, {
    session$setInputs(city_filter = "Tampere", library_search = "", service_filter = "")
    expect_equal(selection()$city, "Tampere")

    session$setInputs(startup_geolocation_timeout = TRUE)
    expect_equal(selection()$city, "Tampere")
    expect_true(startup_city_set())

    session$setInputs(startup_location = list(lat = 60.17, lon = 24.94))   # a second startup event
    expect_equal(selection()$city, "Tampere")
  })
})

test_that("the startup city is used when no city has been chosen", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(fixture_services)

    session$setInputs(startup_geolocation_timeout = TRUE)
    expect_equal(selection()$city, "Helsinki")
    expect_equal(sort(libraries_on_map()$id), c(1, 2))
  })
})

test_that("a normal page load (empty first values) is left alone, and later changes still work", {
  testServer(server, {
    eval(seed_fixture_data_code)

    expect_equal(selection(), list(city = "", service = "", library = ""))

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    expect_equal(selection(), list(city = "Helsinki", service = "", library = "1"))
    expect_equal(eval(ids_on_map), 1)
  })
})

# Regression (reported 2026-10-23): with a service selected, changing to a city
# that doesn't offer it used to leave the library dropdown EMPTY. Under the new
# rules that city isn't offered at all while the service is selected, so the
# change is refused, the city dropdown is sent back to what we hold, and the
# library list stays the one for the selection. updateSelectInput() and
# updateSelectizeInput() can't be read back through testServer() (see the note
# above), so these tests record what the server sends to the browser.
record_dropdown_updates <- function(env = parent.frame()) {
  calls <- new.env()
  calls$sent <- list()
  record <- function(session, inputId, ...) {
    args <- list(...)
    calls$sent[[length(calls$sent) + 1]] <- list(
      id = inputId, choices = args$choices, selected = args$selected
    )
    invisible(NULL)
  }
  # the server looks these up from the global environment, so shadow them there
  assign("updateSelectInput", record, envir = globalenv())
  assign("updateSelectizeInput", record, envir = globalenv())
  assign("showNotification", function(ui, ...) {
    calls$notice <- ui
    invisible(NULL)
  }, envir = globalenv())
  withr::defer({
    rm(list = c("updateSelectInput", "updateSelectizeInput", "showNotification"), envir = globalenv())
  }, envir = env)
  calls
}
last_sent <- function(calls, id) {
  matching <- Filter(function(x) x$id == id, calls$sent)
  if (length(matching)) matching[[length(matching)]] else NULL
}

services_by_city <- data.frame(
  library_id = c(1, 2, 3),
  service_name = c("Printing", "Yoga", "Scanning"),
  stringsAsFactors = FALSE
)

test_that("a city the selected service isn't offered in clears the service with a notice; the city list stays complete", {
  calls <- record_dropdown_updates()

  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(services_by_city)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    # picking a service doesn't narrow the city list
    expect_equal(unname(last_sent(calls, "city_filter")$choices), c("", "Helsinki", "Tampere"))
    calls$sent <- list()

    session$setInputs(city_filter = "Tampere")   # Tampere has no "Printing"
    expect_equal(selection(), list(city = "Tampere", service = "", library = ""))
    expect_equal(calls$notice, "Service cleared: it is not offered in Tampere")
    expect_equal(last_sent(calls, "service_filter")$selected, "")
    expect_equal(eval(ids_on_map), 3)
  })
})

test_that("changing the city sends that city's libraries, and the service list for it", {
  calls <- record_dropdown_updates()

  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(services_by_city)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Tampere")
    expect_equal(unname(last_sent(calls, "library_search")$choices), c("", "3"))
    expect_equal(unname(last_sent(calls, "service_filter")$choices), c("", "Scanning"))
  })
})

test_that("picking a city that doesn't contain the picked library clears it and says so", {
  calls <- record_dropdown_updates()

  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(services_by_city)
    startup_city_set(TRUE)

    session$setInputs(library_search = "1")          # Alpha, Helsinki
    expect_equal(selection()$city, "Helsinki")
    session$setInputs(city_filter = "Tampere")
    expect_equal(selection(), list(city = "Tampere", service = "", library = ""))
    expect_equal(calls$notice, "Library cleared: it is not in Tampere")
    expect_equal(last_sent(calls, "library_search")$selected, "")
  })
})

test_that("the browser echoing a value the server just sent changes nothing", {
  calls <- record_dropdown_updates()

  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(services_by_city)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    before <- selection()
    calls$sent <- list()

    # the echoes of our own updateSelectInput()/updateSelectizeInput() calls
    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    expect_equal(selection(), before)
    expect_length(calls$sent, 0)
  })
})

# Reported 2026-10-23: after clicking the x on the service dropdown the dropdown
# kept showing the cleared service. The x doesn't change the dropdown in the
# browser, so the server has to send the cleared value (it had assumed the
# browser already held it, as it does when the user picks from the dropdown).
test_that("the x buttons send the cleared value to the dropdown", {
  calls <- record_dropdown_updates()

  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(services_by_city)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")   # picked in the dropdown: the browser has it
    session$setInputs(library_search = "1")
    calls$sent <- list()

    session$setInputs(clear_service = 1)              # the dropdown itself is not touched
    expect_equal(selection()$service, "")
    expect_equal(last_sent(calls, "service_filter")$selected, "")

    session$setInputs(clear_library = 1)
    expect_equal(selection()$library, "")
    expect_equal(last_sent(calls, "library_search")$selected, "")
  })
})

test_that("clearing a dropdown by hand doesn't send the value back to it", {
  calls <- record_dropdown_updates()

  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(services_by_city)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    calls$sent <- list()

    session$setInputs(service_filter = "")            # cleared inside the dropdown
    expect_equal(selection()$service, "")
    expect_null(last_sent(calls, "service_filter")$selected)   # nothing sent to it
  })
})

# With no schedule data for today (the nightly update hasn't run yet) every
# library is drawn purple, "no status data". The page says why.
test_that("a notice explains the missing statuses when there is no schedule data for today", {
  testServer(server, {
    eval(seed_fixture_data_code)

    all_library_schedules(data.frame(
      library_id = numeric(), date = character(), from = character(),
      to = character(), status_label = character(), stringsAsFactors = FALSE
    ))
    session$flushReact()
    expect_match(as.character(output$data_notice$html), "not available yet")

    all_library_schedules(data.frame(
      library_id = 1, date = "2026-10-23", from = "08:00", to = "18:00",
      status_label = "Open", stringsAsFactors = FALSE
    ))
    session$flushReact()
    expect_false(any(grepl("not available yet", as.character(output$data_notice$html))))
  })
})

test_that("the map legend explains the 'no status data' colour", {
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(dark_mode = "light", is_mobile = FALSE)
    session$flushReact()
    expect_match(as.character(output$map), "No status data", fixed = TRUE)
    expect_match(as.character(output$map), light_colors$Unknown, fixed = TRUE)
  })
})

# ---- the selection in the page address ----
# testServer()'s session has a fixed fake query string, so the server reads it
# through url_search_of(), which these tests replace. The data comes from the
# app's own fetch functions (replaced by the fixtures), because the link is
# checked when the first data arrives.
with_address <- function(search, env = parent.frame()) {
  names_replaced <- c("url_search_of", "updateQueryString", "fetch_libraries", "fetch_schedules", "fetch_library_services")
  was_global <- vapply(names_replaced, exists, logical(1), envir = globalenv(), inherits = FALSE)
  originals <- mget(names_replaced, envir = globalenv(), inherits = TRUE)
  written <- new.env()
  written$queries <- character()

  assign("url_search_of", function(session) search, envir = globalenv())
  assign("updateQueryString", function(queryString, mode = "replace", session = NULL) {
    written$queries <- c(written$queries, queryString)
    invisible(NULL)
  }, envir = globalenv())
  assign("fetch_libraries", function() {
    fixture_libraries[, c("id", "library_branch_name", "lat", "lon", "city_name",
      "library_url", "library_phone", "library_email", "library_address")]
  }, envir = globalenv())
  assign("fetch_schedules", function() {
    data.frame(library_id = 1:3, date = "2026-10-23", from = "09:00", to = "20:00",
      status_label = "Open", stringsAsFactors = FALSE)
  }, envir = globalenv())
  assign("fetch_library_services", function() fixture_services, envir = globalenv())

  withr::defer(for (name in names_replaced) {
    if (was_global[[name]]) assign(name, originals[[name]], envir = globalenv()) else rm(list = name, envir = globalenv())
  }, envir = env)
  written
}

test_that("a link restores the selection, and the map shows it", {
  written <- with_address("?city=Helsinki&service=Printing")

  testServer(server, {
    session$flushReact()

    expect_equal(selection(), list(city = "Helsinki", service = "Printing", library = ""))
    expect_true(startup_city_set())               # the link decided the city
    expect_equal(sort(libraries_on_map()$id), c(1, 2))
  })
})

test_that("a link with values that don't fit starts from what does, with a notice", {
  written <- with_address("?city=Atlantis&service=Printing")
  shown <- new.env()
  assign("showNotification", function(ui, ...) { shown$text <- ui; invisible(NULL) }, envir = globalenv())
  withr::defer(rm("showNotification", envir = globalenv()))

  testServer(server, {
    session$flushReact()

    expect_equal(selection()$city, "")            # not a real city
    expect_equal(selection()$service, "Printing")
    expect_match(shown$text, "left out")
  })
})

test_that("a page without a link starts as usual and the address follows the selection", {
  written <- with_address("")

  testServer(server, {
    session$flushReact()
    startup_city_set(TRUE)
    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    session$flushReact()

    expect_equal(selection(), list(city = "Helsinki", service = "Printing", library = ""))
    expect_equal(tail(written$queries, 1), "?city=Helsinki&service=Printing")

    session$setInputs(clear_service = 1)
    session$flushReact()
    expect_equal(tail(written$queries, 1), "?city=Helsinki")
  })
})

test_that("the incoming link is not overwritten: the first address written is the link's", {
  written <- with_address("?city=Helsinki")

  testServer(server, {
    session$flushReact()
    expect_gt(length(written$queries), 0)
    expect_equal(written$queries[1], "?city=Helsinki")   # not "?" from an empty selection
  })
})

# If the data is slow or fails to load, the link can't be checked yet; the
# address must stay as it is instead of being overwritten with an empty selection.
test_that("the address is left alone while the data hasn't loaded", {
  written <- with_address("?city=Helsinki&service=Printing")
  assign("fetch_libraries", function() shiny::req(FALSE), envir = globalenv())   # silently produces nothing

  testServer(server, {
    session$flushReact()
    expect_null(library_data())
    expect_length(written$queries, 0)      # nothing written: the link is still intact
    expect_equal(selection(), list(city = "", service = "", library = ""))
  })
})

# ---- Find Nearest ----
# Fixtures: library 1 and 2 (Helsinki, near each other) and 3 (Tampere, far). All open.
nearest_services <- data.frame(
  library_id = c(1, 3), service_name = c("Printing", "Printing"), stringsAsFactors = FALSE
)

test_that("Find Nearest lists the nearest open libraries and the heading says nothing special without a service", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(nearest_services)
    startup_city_set(TRUE)
    session$setInputs(is_mobile = FALSE)

    session$setInputs(user_location = list(lat = 60.1, lon = 24.9))
    expect_equal(nearest_libraries()$id, c(1, 2, 3))
    session$flushReact()
    html <- as.character(output$nearest_libraries_ui$html)
    expect_match(html, "Nearest Open Libraries")
    expect_false(grepl("offering", html, fixed = TRUE))
  })
})

test_that("with a service selected, Find Nearest only lists libraries offering it, and the heading says so", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(nearest_services)
    startup_city_set(TRUE)
    session$setInputs(is_mobile = FALSE)
    session$setInputs(service_filter = "Printing")

    session$setInputs(user_location = list(lat = 60.1, lon = 24.9))
    expect_equal(nearest_libraries()$id, c(1, 3))         # 2 is closer than 3 but has no Printing
    session$flushReact()
    expect_match(as.character(output$nearest_libraries_ui$html), "Nearest open libraries offering Printing")
  })
})

test_that("Find Nearest doesn't touch the dropdowns or the map's selection", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(nearest_services)
    startup_city_set(TRUE)
    session$setInputs(is_mobile = FALSE)
    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    before <- selection()

    session$setInputs(user_location = list(lat = 61.5, lon = 23.7))   # next to the Tampere library
    expect_equal(nearest_libraries()$id[1], 3)            # the nearest is in another city
    expect_equal(selection(), before)
  })
})

test_that("nothing offering the selected service is open: an empty result and a notice that names it", {
  shown <- new.env()
  assign("showNotification", function(ui, ...) { shown$text <- ui; invisible(NULL) }, envir = globalenv())
  withr::defer(rm("showNotification", envir = globalenv()))

  testServer(server, {
    session$flushReact()
    closed <- fixture_libraries
    closed$open_status <- "Closed"
    library_data(closed)
    library_services_data(nearest_services)
    startup_city_set(TRUE)
    session$setInputs(is_mobile = FALSE)
    session$setInputs(service_filter = "Printing")

    session$setInputs(user_location = list(lat = 60.1, lon = 24.9))
    expect_equal(nrow(nearest_libraries()), 0)
    expect_equal(shown$text, "No open libraries offering Printing found nearby")
  })
})

test_that("the nearest list is cleared when the service or the city changes", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(nearest_services)
    startup_city_set(TRUE)
    session$setInputs(is_mobile = FALSE)

    session$setInputs(user_location = list(lat = 60.1, lon = 24.9))
    expect_gt(nrow(nearest_libraries()), 0)
    session$setInputs(service_filter = "Printing")
    expect_null(nearest_libraries())                       # searched without the service
    expect_null(user_location())

    session$setInputs(user_location = list(lat = 60.2, lon = 24.8))
    expect_gt(nrow(nearest_libraries()), 0)
    session$setInputs(city_filter = "Helsinki")
    expect_null(nearest_libraries())

    session$setInputs(user_location = list(lat = 60.3, lon = 24.7))
    expect_gt(nrow(nearest_libraries()), 0)
    session$setInputs(clear_service = 1)
    expect_null(nearest_libraries())
  })
})

# ---- statuses follow the clock ----
# The statuses are recomputed every minute from the loaded schedule rows. The data
# comes from the app's fetch functions (replaced by fixtures) and the clock from
# helsinki_time_now() / helsinki_today() (replaced by a clock the test moves).
clock_rows <- rbind(
  data.frame(library_id = 1, date = "2026-10-23", from = "09:00", to = "10:00", status_label = "Open", stringsAsFactors = FALSE),
  data.frame(library_id = 2, date = "2026-10-23", from = NA_character_, to = NA_character_, status_label = "Closed for the whole day", stringsAsFactors = FALSE),
  data.frame(library_id = 3, date = "2026-10-24", from = "07:00", to = "08:00", status_label = "Open", stringsAsFactors = FALSE)
)

with_clock <- function(time, today = "2026-10-23", env = parent.frame()) {
  names_replaced <- c("fetch_libraries", "fetch_schedules", "fetch_library_services", "helsinki_time_now", "helsinki_today")
  originals <- mget(names_replaced, envir = globalenv(), inherits = TRUE)
  clock <- new.env()
  clock$time <- time
  clock$today <- as.Date(today)

  assign("fetch_libraries", function() {
    fixture_libraries[, c("id", "library_branch_name", "lat", "lon", "city_name",
      "library_url", "library_phone", "library_email", "library_address")]
  }, envir = globalenv())
  assign("fetch_schedules", function() clock_rows, envir = globalenv())
  assign("fetch_library_services", function() fixture_services, envir = globalenv())
  assign("helsinki_time_now", function() clock$time, envir = globalenv())
  assign("helsinki_today", function(now = Sys.time()) clock$today, envir = globalenv())

  withr::defer(for (name in names_replaced) assign(name, originals[[name]], envir = globalenv()), envir = env)
  clock
}
# Evaluated inside testServer() (where library_data() exists), not defined here
status_now_code <- quote(status_now <- function(id) library_data()$open_status[library_data()$id == id])

test_that("a library that opens while the page is open changes status without a reload", {
  clock <- with_clock("08:59")

  testServer(server, {
    eval(status_now_code)
    session$flushReact()
    expect_equal(status_now(1), "Closed")
    expect_equal(status_clock(), "08:59")

    clock$time <- "09:00"                       # the library opens
    session$elapse(61 * 1000)                   # the page's minute check
    expect_equal(status_now(1), "Open")
    expect_equal(library_data()$opening_hours[library_data()$id == 1], "09:00 - 10:00")
    expect_equal(status_clock(), "09:00")
    # and what the map shows follows
    expect_equal(libraries_on_map()$open_status[libraries_on_map()$id == 1], "Open")

    clock$time <- "10:01"                       # and closes again
    session$elapse(61 * 1000)
    expect_equal(status_now(1), "Closed")
  })
})

test_that("a minute with no change doesn't replace the data, so the map isn't redrawn", {
  clock <- with_clock("09:30")

  testServer(server, {
    session$flushReact()
    replaced <- 0
    observeEvent(library_data(), replaced <<- replaced + 1, ignoreInit = TRUE)

    session$elapse(61 * 1000)                   # same time, nothing changed
    session$elapse(61 * 1000)
    expect_equal(replaced, 0)

    clock$time <- "10:01"                       # now library 1 closes
    session$elapse(61 * 1000)
    expect_equal(replaced, 1)
  })
})

test_that("the library whose details are open gets its new status too", {
  clock <- with_clock("08:59")

  testServer(server, {
    session$flushReact()
    selected_library(library_data()[library_data()$id == 1, ])
    expect_equal(selected_library()$open_status, "Closed")

    clock$time <- "09:15"
    session$elapse(61 * 1000)
    expect_equal(selected_library()$open_status, "Open")
    expect_equal(selected_library()$id, 1)
  })
})

test_that("a page left open past midnight switches to the new day's schedule", {
  clock <- with_clock("23:59", today = "2026-10-23")

  testServer(server, {
    eval(status_now_code)
    session$flushReact()
    expect_true(is.na(status_now(3)))                       # library 3 has no rows today
    expect_equal(unique(all_library_schedules()$date), "2026-10-23")

    clock$today <- as.Date("2026-10-24"); clock$time <- "07:30"
    session$elapse(61 * 1000)
    expect_equal(status_now(3), "Open")                    # tomorrow's row, loaded with the page
    expect_equal(unique(all_library_schedules()$date), "2026-10-24")
    expect_true(is.na(status_now(1)))                       # library 1 has no rows for the 24th
  })
})

test_that("the library details show the time they were computed for", {
  clock <- with_clock("09:30")

  testServer(server, {
    session$flushReact()
    selected_library(library_data()[library_data()$id == 1, ])
    session$flushReact()
    expect_match(as.character(output$library_services$html), "09:00-10:00 \\(Open\\) \u2190 now")

    clock$time <- "10:30"
    session$elapse(61 * 1000)
    session$flushReact()
    expect_false(grepl("\u2190 now", as.character(output$library_services$html), fixed = TRUE))
  })
})

# ---- the search box ("Search all libraries") ----
# It offers every library whatever the filters hold; picking one jumps to it (its
# city and the library) through the same selection, and the box empties again.

test_that("the search box is filled with every library once the data has arrived", {
  calls <- record_dropdown_updates()
  testServer(server, {
    session$flushReact()
    sent <- last_sent(calls, "library_finder")
    expect_false(is.null(sent))
    expect_equal(unname(sent$choices), c("", "1", "2", "3"))
    expect_equal(names(sent$choices), c("", "Alpha Library (Helsinki)", "Beta Library (Helsinki)", "Gamma Library (Tampere)"))
  })
})

test_that("picking a library in another city jumps to it, and the box empties", {
  calls <- record_dropdown_updates()
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(city_filter = "Helsinki")
    expect_equal(eval(ids_on_map), c(1, 2))
    calls$sent <- list()

    session$setInputs(library_finder = "3")          # Gamma, in Tampere
    expect_equal(selection(), list(city = "Tampere", service = "", library = "3"))
    expect_equal(eval(ids_on_map), 3)
    expect_equal(selected_library()$id, 3)
    expect_equal(last_sent(calls, "library_finder")$selected, "")
    expect_equal(last_sent(calls, "city_filter")$selected, "Tampere")
    expect_equal(last_sent(calls, "library_search")$selected, "3")
  })
})

test_that("the search box keeps a service the library offers, and clears one it doesn't, with a notice", {
  calls <- record_dropdown_updates()
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(service_filter = "Printing")          # Alpha and Beta have it, Gamma doesn't
    calls$notice <- NULL

    session$setInputs(library_finder = "2")
    expect_equal(selection(), list(city = "Helsinki", service = "Printing", library = "2"))
    expect_null(calls$notice)

    session$setInputs(library_finder = "3")
    expect_equal(selection(), list(city = "Tampere", service = "", library = "3"))
    expect_equal(calls$notice, "Service cleared: Gamma Library does not offer Printing")
    expect_equal(last_sent(calls, "service_filter")$selected, "")
  })
})

test_that("an unknown library or an emptied box changes nothing", {
  calls <- record_dropdown_updates()
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(city_filter = "Helsinki")
    before <- selection()
    session$setInputs(library_finder = "999")
    expect_equal(selection(), before)
    session$setInputs(library_finder = "")
    expect_equal(selection(), before)
  })
})

test_that("the search box doesn't disturb the dropdowns: picking in the dropdowns still works afterwards", {
  record_dropdown_updates()
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(library_finder = "3")
    session$setInputs(library_search = "")           # the x on the library dropdown
    expect_equal(selection(), list(city = "Tampere", service = "", library = ""))
    session$setInputs(city_filter = "Helsinki")
    expect_equal(eval(ids_on_map), c(1, 2))
  })
})

# ---- All Cities ----
# An empty city is a choice ("All Cities"): every library on the map. It must
# survive a reload (the address says `city=`) and not be replaced by the starting
# city, which comes from the location and may still be on its way.

test_that("choosing All Cities shows every library, clears a library and keeps the service", {
  calls <- record_dropdown_updates()
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    calls$notice <- NULL

    session$setInputs(city_filter = "")
    expect_equal(selection(), list(city = "", service = "", library = ""))
    expect_equal(eval(ids_on_map), c(1, 2, 3))
    expect_equal(calls$notice, "Library cleared: all cities are shown")
    expect_null(selected_library())
    expect_equal(last_sent(calls, "city_filter")$selected, "")
  })
})

test_that("All Cities keeps a selected service", {
  record_dropdown_updates()
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    session$setInputs(city_filter = "")
    expect_equal(selection(), list(city = "", service = "Printing", library = ""))
    expect_equal(eval(ids_on_map), c(1, 2))
  })
})

test_that("the summary says All Cities once the starting city is decided", {
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(city_filter = "Helsinki")
    session$setInputs(city_filter = "")
    session$flushReact()
    expect_equal(output$filter_summary, "3 libraries · All Cities")
  })
})

test_that("All Cities is written to the address as an empty city=", {
  written <- with_address("?city=Helsinki")
  testServer(server, {
    session$flushReact()
    session$setInputs(city_filter = "")
    session$flushReact()
    expect_equal(tail(written$queries, 1), "?city=")
  })
})

test_that("a link with an empty city= opens on All Cities, and the starting city doesn't replace it", {
  written <- with_address("?city=")
  testServer(server, {
    session$flushReact()
    expect_equal(selection(), list(city = "", service = "", library = ""))
    expect_true(startup_city_set())                       # the link decided: no waiting for the location
    expect_equal(eval(ids_on_map), c(1, 2, 3))
    expect_equal(tail(written$queries, 1), "?city=")      # the address keeps saying so

    session$setInputs(startup_location = list(lat = 60.1, lon = 24.9))   # the location arrives late
    expect_equal(selection()$city, "")
  })
})

test_that("a link with an empty city= and a service opens on that service in all cities", {
  with_address("?city=&service=Printing")
  testServer(server, {
    session$flushReact()
    expect_equal(selection(), list(city = "", service = "Printing", library = ""))
    expect_equal(eval(ids_on_map), c(1, 2))
  })
})

test_that("choosing All Cities before the location arrives is not overridden by it", {
  record_dropdown_updates()
  testServer(server, {
    session$flushReact()                  # data loaded; the starting city isn't known yet
    expect_false(startup_city_set())
    session$setInputs(city_filter = "Helsinki")
    session$setInputs(city_filter = "")
    expect_true(startup_city_set())
    session$setInputs(startup_location = list(lat = 61.5, lon = 23.7))
    expect_equal(selection()$city, "")
  })
})

test_that("without a choice, the address stays empty until the starting city is known", {
  written <- with_address("")
  testServer(server, {
    session$flushReact()
    expect_false(startup_city_set())
    expect_true(all(written$queries %in% character()) || !any(written$queries == "?city="))
  })
})
