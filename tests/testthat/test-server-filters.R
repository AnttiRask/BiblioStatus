# Regression tests for the filter-cascade bugs fixed in Plan 1 (fixes.md:4-5):
#   1. Clearing library/service filters must update committed_* immediately,
#      without requiring "Show on Map" to be pressed again.
#   2. The service dropdown's displayed value must stay in sync with whether
#      the selected service is still valid for the currently selected city.
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
seed_fixture_data_code <- quote({
  session$flushReact()
  library_data(fixture_libraries)
  library_services_data(fixture_services)
  startup_city_set(TRUE)
})

test_that("clearing the library filter updates committed_library immediately", {
  testServer(server, {
    eval(seed_fixture_data_code)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    session$setInputs(apply_filters = 1)
    expect_equal(committed_library(), "1")

    session$setInputs(clear_library = 1)
    expect_equal(committed_library(), "")
  })
})

test_that("clearing the service filter updates committed_service immediately", {
  testServer(server, {
    eval(seed_fixture_data_code)

    session$setInputs(service_filter = "Printing")
    session$setInputs(apply_filters = 1)
    expect_equal(committed_service(), "Printing")

    session$setInputs(clear_service = 1)
    expect_equal(committed_service(), "")
  })
})

# Regression test for a bug reported after Plan 1/7/8/9/10: clicking the ×
# clear button, then immediately clicking "Show on Map" before the browser's
# updateSelectInput() round-trip echoes the cleared value back to
# input$service_filter/input$library_search, committed the STALE
# pre-clear value instead of "". testServer() never simulates that round-trip
# at all (see the NOTE below), which makes it a perfect stand-in for "the
# round-trip hasn't landed yet" - input$service_filter genuinely stays at its
# old value here even after clear_service fires, exactly like the real race.
# apply_filters must not use input$service_filter/input$library_search
# directly for this reason; see pending_service/pending_library in server.R.
test_that("Show on Map after clearing a filter commits the clear, not the stale input$ value", {
  testServer(server, {
    eval(seed_fixture_data_code)

    session$setInputs(service_filter = "Printing")
    session$setInputs(apply_filters = 1)
    expect_equal(committed_service(), "Printing")

    # Simulate clicking × then "Show on Map" before the browser round-trip:
    # input$service_filter is deliberately left at "Printing".
    session$setInputs(clear_service = 1)
    session$setInputs(apply_filters = 2)
    expect_equal(committed_service(), "")
  })
})

test_that("Show on Map after clearing the library filter commits the clear, not the stale input$ value", {
  testServer(server, {
    eval(seed_fixture_data_code)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    session$setInputs(apply_filters = 1)
    expect_equal(committed_library(), "1")

    # Simulate clicking × then "Show on Map" before the browser round-trip:
    # input$library_search is deliberately left at "1".
    session$setInputs(clear_library = 1)
    session$setInputs(apply_filters = 2)
    expect_equal(committed_library(), "")
  })
})

# Reported bug: select a service that only leaves one library choice, select
# that library (not just leave it as the only option - actually select it),
# "Show on Map", then clear the SERVICE only. The library filter was never
# an independent choice - it only existed because the service narrowed the
# dropdown to one entry - so clearing the service must clear the library too.
# Before the fix, clear_service only touched service_filter/pending_service,
# leaving the library filter (and the map) stuck on the single library.
test_that("clearing the service filter also clears an implied library selection", {
  testServer(server, {
    eval(seed_fixture_data_code)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Printing")
    session$setInputs(library_search = "1")
    session$setInputs(apply_filters = 1)
    expect_equal(committed_service(), "Printing")
    expect_equal(committed_library(), "1")

    session$setInputs(clear_service = 1)
    expect_equal(committed_service(), "")
    expect_equal(committed_library(), "")

    session$setInputs(apply_filters = 2)
    expect_equal(committed_service(), "")
    expect_equal(committed_library(), "")
  })
})

# Reported feature request: the service dropdown should show city-wide
# services until a library is selected, then narrow to just that library's
# own services. Uses fixture_services_distinct (library 1: Printing +
# Scanning, library 2: Yoga only) so the two libraries' service sets differ.
test_that("selecting a library resets an incompatible service selection", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(fixture_services_distinct)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(service_filter = "Yoga")
    expect_equal(pending_service(), "Yoga")

    # Library 1 doesn't offer Yoga (only library 2 does) - selecting it must
    # reset the service selection rather than keep an invalid one selected.
    session$setInputs(library_search = "1")
    expect_equal(pending_service(), "")
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
    expect_equal(pending_service(), "Printing")

    # Library 1 does offer Printing - selecting it must keep the selection.
    session$setInputs(library_search = "1")
    expect_equal(pending_service(), "Printing")
  })
})

test_that("clearing the library widens the service selection back to city scope", {
  testServer(server, {
    session$flushReact()
    library_data(fixture_libraries)
    library_services_data(fixture_services_distinct)
    startup_city_set(TRUE)

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    session$setInputs(service_filter = "Printing")
    expect_equal(pending_service(), "Printing")

    session$setInputs(clear_library = 1)
    # Printing is still valid at the city level (library 1 offers it), so it
    # should be re-affirmed, not wiped, once the library constraint is gone.
    expect_equal(pending_service(), "Printing")
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

test_that("the rendered map uses dark tiles and the dark marker palette in dark mode", {
  testServer(server, {
    eval(seed_fixture_data_code)
    session$setInputs(dark_mode = "light", is_mobile = FALSE)
    session$flushReact()
    light_map <- as.character(output$map)
    expect_match(light_map, "World_Light_Gray_Base", fixed = TRUE)
    expect_false(grepl("World_Dark_Gray", light_map, fixed = TRUE))
    expect_match(light_map, light_colors$Open, fixed = TRUE)

    session$setInputs(dark_mode = "dark")
    session$flushReact()
    dark_map <- as.character(output$map)
    expect_match(dark_map, "World_Dark_Gray_Base", fixed = TRUE)
    expect_match(dark_map, "World_Dark_Gray_Reference", fixed = TRUE)
    expect_false(grepl("World_Light_Gray", dark_map, fixed = TRUE))
    expect_match(dark_map, dark_colors$Open, fixed = TRUE)
  })
})

# After a reconnect (session$allowReconnect("force")) the browser re-sends all
# the dropdown values and the "Show on Map" click count as the new session's
# FIRST values, in one go. testServer() does the same when the very first
# setInputs() call carries them all (so no session$flushReact() before it,
# unlike seed_fixture_data_code, which would use up the first flush).
test_that("a reconnect restores the committed library, so the map and Show on Map agree with the dropdowns", {
  testServer(server, {
    session$setInputs(
      city_filter = "Tampere", library_search = "3", service_filter = "Printing",
      apply_filters = 1
    )

    expect_equal(pending_library(), "3")
    expect_equal(pending_service(), "Printing")
    expect_equal(committed_city(), "Tampere")
    expect_equal(committed_library(), "3")
    expect_equal(committed_service(), "Printing")
  })
})

test_that("a reconnect before Show on Map was ever pressed still restores the city the map shows", {
  testServer(server, {
    session$setInputs(city_filter = "Helsinki", library_search = "", service_filter = "")

    expect_equal(committed_city(), "Helsinki")
    expect_equal(committed_library(), "")
    expect_equal(committed_service(), "")
    expect_equal(pending_library(), "")
  })
})

test_that("a normal page load (empty first values) is left alone, and later changes still work", {
  testServer(server, {
    eval(seed_fixture_data_code)

    expect_equal(committed_city(), "")
    expect_equal(pending_library(), "")
    expect_equal(pending_service(), "")

    session$setInputs(city_filter = "Helsinki")
    session$setInputs(library_search = "1")
    session$setInputs(apply_filters = 1)
    expect_equal(pending_library(), "1")
    expect_equal(committed_library(), "1")
  })
})
