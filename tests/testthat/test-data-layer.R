# get_app_data(): never throws, shared cache, stale fallback, notices.
# The fetch functions are replaced (looked up by name when called) and the
# cache is switched on only for the tests that are about it.

libs_fixture <- data.frame(id = 1:2, library_branch_name = c("A", "B"), stringsAsFactors = FALSE)
sched_fixture <- data.frame(library_id = 1:2, date = "2026-10-24", from = "09:00", to = "17:00",
                            status_label = "Open", stringsAsFactors = FALSE)
serv_fixture <- data.frame(library_id = 1L, service_name = "Sauna", stringsAsFactors = FALSE)

from_sqlite <- function(x) structure(x, source = "sqlite")

# Replace fetch_*() for the calling test, count the calls, and restore afterwards.
# Each argument is a function returning the data (or stopping).
with_fetchers <- function(libraries = function() libs_fixture,
                          schedules = function() sched_fixture,
                          services = function() serv_fixture,
                          env = parent.frame()) {
  calls <- new.env()
  calls$libraries <- calls$schedules <- calls$services <- 0
  fns <- list(
    fetch_libraries = function() { calls$libraries <- calls$libraries + 1; libraries() },
    fetch_schedules = function() { calls$schedules <- calls$schedules + 1; schedules() },
    fetch_library_services = function() { calls$services <- calls$services + 1; services() }
  )
  originals <- mget(names(fns), envir = globalenv(), inherits = TRUE)
  was_global <- vapply(names(fns), exists, logical(1), envir = globalenv(), inherits = FALSE)
  for (name in names(fns)) assign(name, fns[[name]], envir = globalenv())
  withr::defer(for (name in names(fns)) {
    if (was_global[[name]]) assign(name, originals[[name]], envir = globalenv()) else rm(list = name, envir = globalenv())
  }, envir = env)
  calls
}

# Cache on, empty, and off again afterwards
with_cache <- function(seconds = 300, env = parent.frame()) {
  old <- options(bibliostatus.data_cache_seconds = seconds)
  data_cache_clear()
  withr::defer({ options(old); data_cache_clear() }, envir = env)
}

t0 <- as.POSIXct("2026-10-24 10:00:00", tz = "UTC")
dates_today <- c("2026-10-24", "2026-10-25")

test_that("a complete read from Turso gives the data and no error", {
  with_fetchers()
  d <- load_app_data(t0)
  expect_equal(d$source, "turso")
  expect_null(d$error)
  expect_false(d$stale)
  expect_equal(d$libraries, libs_fixture)
  expect_null(attr(d$libraries, "source"))     # the source tag is not left on the data
  expect_equal(d$fetched_at, t0)
})

test_that("the backup is reported when any part came from it", {
  with_fetchers(schedules = function() from_sqlite(sched_fixture))
  d <- load_app_data(t0)
  expect_equal(d$source, "sqlite")
  expect_equal(d$schedules, sched_fixture)
})

test_that("it never throws: libraries failing means nothing to show", {
  with_fetchers(libraries = function() stop("both databases are down"))
  d <- expect_no_error(load_app_data(t0))
  expect_equal(d$source, "none")
  expect_null(d$libraries)
  expect_match(d$error, "libraries: both databases are down")
})

test_that("a silent Shiny condition from a fetch is an error too, not a crash", {
  with_fetchers(libraries = function() shiny::req(FALSE))
  expect_equal(load_app_data(t0)$source, "none")
})

test_that("no libraries at all counts as nothing to show", {
  with_fetchers(libraries = function() libs_fixture[0, ])
  d <- load_app_data(t0)
  expect_equal(d$source, "none")
  expect_match(d$error, "no libraries")
})

test_that("missing schedules or services degrade the data but keep the libraries", {
  with_fetchers(schedules = function() stop("schedules failed"), services = function() stop("services failed"))
  d <- load_app_data(t0)
  expect_equal(d$source, "turso")
  expect_equal(d$libraries, libs_fixture)
  expect_equal(nrow(d$schedules), 0)
  expect_equal(names(d$schedules), c("library_id", "date", "from", "to", "status_label"))
  expect_equal(names(d$services), c("library_id", "service_name"))
  expect_match(d$error, "schedules: schedules failed")
  expect_match(d$error, "services: services failed")
})

test_that("the statuses can be computed from the degraded (empty) schedules", {
  with_fetchers(schedules = function() stop("down"))
  d <- load_app_data(t0)
  libs <- data.frame(id = 1:2, library_branch_name = c("A", "B"), lat = 60, lon = 24,
                     city_name = "Helsinki", library_url = NA, library_phone = NA,
                     library_email = NA, library_address = "x", stringsAsFactors = FALSE)
  out <- expect_no_error(compute_library_statuses(libs, d$schedules, "2026-10-24", "10:00"))
  expect_equal(nrow(out), 2)
})

# ---- the shared cache ----

test_that("the data is shared: a second read within the time doesn't ask the databases", {
  with_cache(300)
  calls <- with_fetchers()
  first <- get_app_data(t0, dates_today)
  second <- get_app_data(t0 + 299, dates_today)
  expect_identical(second, first)
  expect_equal(c(calls$libraries, calls$schedules, calls$services), c(1, 1, 1))
})

test_that("after the time it reads again", {
  with_cache(300)
  calls <- with_fetchers()
  get_app_data(t0, dates_today)
  get_app_data(t0 + 301, dates_today)
  expect_equal(calls$libraries, 2)
})

test_that("a new day reads again even inside the time", {
  with_cache(300)
  calls <- with_fetchers()
  get_app_data(t0, dates_today)
  get_app_data(t0 + 10, c("2026-10-25", "2026-10-26"))
  expect_equal(calls$libraries, 2)
})

test_that("with the cache off every call reads", {
  with_cache(0)
  calls <- with_fetchers()
  get_app_data(t0, dates_today)
  get_app_data(t0, dates_today)
  expect_equal(calls$libraries, 2)
})

test_that("Turso failing after a good read shows the earlier data, marked stale", {
  with_cache(300)
  mode <- "up"
  with_fetchers(
    libraries = function() if (mode == "up") libs_fixture else from_sqlite(libs_fixture[1, ])
  )
  get_app_data(t0, dates_today)
  mode <- "down"
  d <- get_app_data(t0 + 400, dates_today)
  expect_true(d$stale)
  expect_equal(d$source, "turso")
  expect_equal(d$libraries, libs_fixture)          # not the backup's one library
  expect_equal(d$fetched_at, t0)                   # the time of the data, not of the failed read
  expect_false(is.null(d$error))
})

test_that("a failed read isn't repeated for every visitor, and is retried after a while", {
  with_cache(300)
  mode <- "down"
  calls <- with_fetchers(libraries = function() if (mode == "down") stop("down") else libs_fixture)

  get_app_data(t0, dates_today)
  get_app_data(t0 + 10, dates_today)
  get_app_data(t0 + 29, dates_today)
  expect_equal(calls$libraries, 1)

  mode <- "up"
  d <- get_app_data(t0 + 31, dates_today)
  expect_equal(calls$libraries, 2)
  expect_equal(d$source, "turso")
  expect_false(d$stale)
  expect_null(d$error)
})

test_that("older data than the limit isn't shown as stale", {
  with_cache(300)
  mode <- "up"
  with_fetchers(libraries = function() if (mode == "up") libs_fixture else from_sqlite(libs_fixture[1, ]))
  get_app_data(t0, dates_today)
  mode <- "down"
  d <- get_app_data(t0 + data_max_stale_seconds + 1, dates_today)
  expect_false(d$stale)
  expect_equal(d$source, "sqlite")
})

test_that("yesterday's data isn't shown as stale on a new day (it has no rows for today)", {
  with_cache(300)
  mode <- "up"
  with_fetchers(libraries = function() if (mode == "up") libs_fixture else from_sqlite(libs_fixture[1, ]))
  get_app_data(t0, dates_today)
  mode <- "down"
  d <- get_app_data(t0 + 400, c("2026-10-25", "2026-10-26"))
  expect_false(d$stale)
  expect_equal(d$source, "sqlite")
})

test_that("without earlier data, the backup is what is shown", {
  with_cache(300)
  with_fetchers(libraries = function() from_sqlite(libs_fixture))
  d <- get_app_data(t0, dates_today)
  expect_equal(d$source, "sqlite")
  expect_false(d$stale)
})

# ---- what the page says ----

test_that("the notice says what is wrong, and nothing when all is well", {
  live <- list(source = "turso", fetched_at = t0, stale = FALSE, error = NULL)
  expect_null(data_notice_for(live, schedules_empty = FALSE))
  expect_equal(data_notice_for(live, schedules_empty = TRUE)$text, txt$no_schedules_notice)
  expect_null(data_notice_for(NULL, schedules_empty = TRUE))

  expect_equal(data_notice_for(modifyList(live, list(source = "none")), FALSE)$class, "alert-danger")
  expect_equal(data_notice_for(modifyList(live, list(source = "none")), FALSE)$text, txt$data_failed_notice)

  backup <- data_notice_for(modifyList(live, list(source = "sqlite")), schedules_empty = TRUE)
  expect_equal(backup$text, txt$data_backup_notice)      # not the "updated every morning" one
  expect_equal(backup$class, "alert-info")

  stale <- data_notice_for(modifyList(live, list(stale = TRUE, error = "x")), FALSE)
  expect_match(stale$text, "13:00", fixed = TRUE)         # 10:00 UTC is 13:00 in Helsinki in October
  expect_equal(stale$class, "alert-info")

  expect_equal(data_notice_for(modifyList(live, list(error = "schedules: x")), FALSE)$text, txt$data_partial_notice)
})

test_that("each state has a different message, none empty", {
  texts <- c(txt$data_backup_notice, txt$data_stale_notice, txt$data_failed_notice, txt$data_partial_notice, txt$no_schedules_notice)
  expect_true(all(nzchar(texts)))
  expect_equal(anyDuplicated(texts), 0)
})
