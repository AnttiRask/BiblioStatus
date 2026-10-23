# The page when the data is not the live data, or can't be loaded at all, and
# the data shared between sessions. The fetch functions are replaced.

srv_libs <- data.frame(
  id = 1:2, library_branch_name = c("A", "B"), lat = c(60.17, 60.18), lon = c(24.94, 24.95),
  city_name = "Helsinki", library_url = NA_character_, library_phone = NA_character_,
  library_email = NA_character_, library_address = "x", stringsAsFactors = FALSE
)
srv_sched <- data.frame(library_id = 1:2, date = format(helsinki_today(), "%Y-%m-%d"),
                        from = "00:00", to = "23:59", status_label = "Open", stringsAsFactors = FALSE)
srv_serv <- data.frame(library_id = 1L, service_name = "Sauna", stringsAsFactors = FALSE)

with_server_fetchers <- function(libraries, schedules = function() srv_sched,
                                 services = function() srv_serv, env = parent.frame()) {
  calls <- new.env()
  calls$libraries <- 0
  fns <- list(
    fetch_libraries = function() { calls$libraries <- calls$libraries + 1; libraries() },
    fetch_schedules = schedules,
    fetch_library_services = services
  )
  originals <- mget(names(fns), envir = globalenv(), inherits = TRUE)
  was_global <- vapply(names(fns), exists, logical(1), envir = globalenv(), inherits = FALSE)
  for (name in names(fns)) assign(name, fns[[name]], envir = globalenv())
  withr::defer(for (name in names(fns)) {
    if (was_global[[name]]) assign(name, originals[[name]], envir = globalenv()) else rm(list = name, envir = globalenv())
  }, envir = env)
  calls
}

notice_html <- function(output) paste(as.character(output$data_notice$html), collapse = "")

test_that("the page loads the data and shows no notice when all is well", {
  with_server_fetchers(function() srv_libs)
  testServer(server, {
    session$flushReact()
    expect_equal(nrow(library_data()), 2)
    expect_equal(data_state()$source, "turso")
    expect_false(grepl("alert", notice_html(output)))
  })
})

test_that("the page says so when it is on the nightly backup", {
  with_server_fetchers(function() structure(srv_libs, source = "sqlite"),
                       schedules = function() structure(srv_sched[0, ], source = "sqlite"))
  testServer(server, {
    session$flushReact()
    expect_equal(nrow(library_data()), 2)          # the map still has the libraries
    expect_match(notice_html(output), "nightly backup", fixed = TRUE)
    expect_false(grepl("updated every morning", notice_html(output), fixed = TRUE))
  })
})

test_that("the page says so, and doesn't crash, when nothing can be loaded", {
  with_server_fetchers(function() stop("Turso and the backup are both down"))
  testServer(server, {
    expect_no_error(session$flushReact())
    expect_null(library_data())
    expect_equal(data_state()$source, "none")
    expect_match(notice_html(output), "could not be loaded", fixed = TRUE)
    expect_match(notice_html(output), "alert-danger", fixed = TRUE)
  })
})

test_that("failing schedules still show the libraries, with a note", {
  with_server_fetchers(function() srv_libs, schedules = function() stop("schedules query failed"))
  testServer(server, {
    session$flushReact()
    expect_equal(nrow(library_data()), 2)
    expect_true(all(is.na(library_data()$open_status)))     # NA is drawn as "no status data"
    expect_match(notice_html(output), "Some of the data could not be loaded", fixed = TRUE)
  })
})

test_that("two sessions share one read of the data", {
  old <- options(bibliostatus.data_cache_seconds = 300)
  data_cache_clear()
  withr::defer({ options(old); data_cache_clear() })
  calls <- with_server_fetchers(function() srv_libs)

  testServer(server, { session$flushReact(); expect_equal(nrow(library_data()), 2) })
  testServer(server, { session$flushReact(); expect_equal(nrow(library_data()), 2) })
  expect_equal(calls$libraries, 1)
})
