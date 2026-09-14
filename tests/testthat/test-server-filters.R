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
