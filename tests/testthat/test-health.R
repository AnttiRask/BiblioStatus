# GET /health (app/www/health.R): what the uptime monitor sees.

source(here::here("app/www/security.R"))   # for the wrapper test at the end

today <- as.Date("2026-10-23")
probe <- function(source = "turso", libraries = 719L, schedules_today = 1400L, newest_date = "2026-10-29") {
  list(source = source, libraries = libraries, schedules_today = schedules_today, newest_date = newest_date)
}
status <- function(...) health_status(probe(...), today = today, min_days_ahead = 2)

test_that("healthy data: 200 and 'ok'", {
  r <- status()
  expect_true(r$ok)
  expect_equal(r$body, "ok")
})

test_that("nothing can be read: unavailable", {
  r <- status(source = "none", libraries = 0L, schedules_today = 0L, newest_date = NA_character_)
  expect_false(r$ok)
  expect_match(r$body, "^unavailable: ")
})

test_that("no libraries: empty", {
  r <- status(libraries = 0L)
  expect_false(r$ok)
  expect_match(r$body, "^empty: ")
})

test_that("no opening hours for today: no_schedules (the 'every dot is purple' case)", {
  r <- status(schedules_today = 0L, newest_date = "2026-10-22")
  expect_false(r$ok)
  expect_match(r$body, "no_schedules")
  expect_false(grepl("stale", r$body))               # one clear reason, not two
})

test_that("the nightly update falling behind is flagged days before visitors notice", {
  # a week is stored every night, so a healthy newest date is about 6 days ahead
  expect_true(status(newest_date = "2026-10-29")$ok)    # today + 6
  expect_true(status(newest_date = "2026-10-26")$ok)    # today + 3: a few missed nights are tolerated
  expect_true(status(newest_date = "2026-10-25")$ok)    # today + 2: still enough
  r <- status(newest_date = "2026-10-24")               # today + 1
  expect_false(r$ok)
  expect_match(r$body, "stale: the newest opening hours are for 2026-10-24")
})

test_that("an unreadable newest date is stale, not an error", {
  r <- status(newest_date = "not a date")
  expect_false(r$ok)
  expect_match(r$body, "stale: .*unreadable date")
  expect_false(status(newest_date = NA_character_)$ok)
})

test_that("the SQLite backup in use is degraded, even when the backup's data is fine", {
  r <- status(source = "sqlite")
  expect_false(r$ok)
  expect_match(r$body, "^degraded: ")
})

test_that("several problems are all listed", {
  r <- status(source = "sqlite", schedules_today = 0L)
  expect_match(r$body, "no_schedules")
  expect_match(r$body, "degraded")
  expect_match(r$body, "; ", fixed = TRUE)
})

test_that("NA counts count as nothing there, not as an error", {
  expect_match(status(libraries = NA_integer_)$body, "^empty: ")
  expect_match(status(schedules_today = NA_integer_)$body, "no_schedules")
})

test_that("the reasons never contain error details", {
  r <- status(source = "none", libraries = 0L, schedules_today = 0L, newest_date = NA_character_)
  expect_false(grepl("http|libsql|token|secret|Error", r$body, ignore.case = TRUE))
})

# ---- the probe ----
# turso_query and db_path are globals (from R/turso.R and functions.R): replace them
# for one test and put the originals back afterwards.
with_replaced <- function(..., env = parent.frame()) {
  replacements <- list(...)
  originals <- mget(names(replacements), envir = globalenv())
  for (name in names(replacements)) assign(name, replacements[[name]], envir = globalenv())
  withr::defer(for (name in names(originals)) assign(name, originals[[name]], envir = globalenv()), envir = env)
}

test_that("the probe reads Turso first", {
  asked <- character()
  with_replaced(turso_query = function(sql, params = list()) {
    asked <<- c(asked, sql)
    if (grepl("MAX\\(date\\)", sql)) data.frame(newest = "2026-10-29")
    else if (grepl("FROM libraries", sql)) data.frame(n = 719L)
    else data.frame(n = 1400L)
  })

  r <- health_probe(today = "2026-10-23")
  expect_equal(r$source, "turso")
  expect_equal(r$libraries, 719L)
  expect_equal(r$schedules_today, 1400L)
  expect_equal(r$newest_date, "2026-10-29")
  expect_length(asked, 3)
})

test_that("when Turso fails the probe reads the SQLite backup", {
  with_replaced(turso_query = function(...) stop("Turso is down"))
  r <- health_probe(today = "2026-10-23")
  expect_equal(r$source, "sqlite")
  expect_gt(r$libraries, 600)                      # the backup in the repo has the libraries
  expect_type(r$schedules_today, "integer")
  expect_equal(health_status(r, today = today)$ok, FALSE)   # a backup in use is always reported
})

test_that("when neither can be read the probe says so, without an error", {
  with_replaced(turso_query = function(...) stop("Turso is down"), db_path = "/nonexistent/none.sqlite")
  r <- health_probe(today = "2026-10-23")
  expect_equal(r$source, "none")
  expect_match(health_status(r, today = today)$body, "^unavailable: ")
})

# ---- the request wrapper ----

fake_app <- function() list(httpHandler = function(req) "the app's answer")
request <- function(path, method = "GET") list(PATH_INFO = path, REQUEST_METHOD = method)

test_that("GET /health gets 200 and ok when healthy, 503 and the reason when not", {
  healthy <- with_health_check(fake_app(), check = function() list(ok = TRUE, body = "ok"))
  r <- healthy$httpHandler(request("/health"))
  expect_equal(r$status, 200L)
  expect_equal(r$content, "ok")
  expect_match(r$content_type, "text/plain")
  expect_equal(r$headers[["Cache-Control"]], "no-store")

  sick <- with_health_check(fake_app(), check = function() list(ok = FALSE, body = "no_schedules: there are no opening hours for today"))
  r <- sick$httpHandler(request("/health"))
  expect_equal(r$status, 503L)
  expect_match(r$content, "no_schedules")
})

test_that("HEAD works too, other methods and other paths go to the app", {
  app <- with_health_check(fake_app(), check = function() list(ok = TRUE, body = "ok"))
  expect_equal(app$httpHandler(request("/health", "HEAD"))$status, 200L)
  expect_equal(app$httpHandler(request("/health", "POST")), "the app's answer")
  expect_equal(app$httpHandler(request("/")), "the app's answer")
  expect_equal(app$httpHandler(request("/health/x")), "the app's answer")
  expect_equal(app$httpHandler(request("/healthz")), "the app's answer")
})

test_that("a health check that itself fails is a 503, not a crash, and says nothing about why", {
  app <- with_health_check(fake_app(), check = function() stop("secret token abc123 in the message"))
  r <- suppressMessages(app$httpHandler(request("/health")))
  expect_equal(r$status, 503L)
  expect_match(r$content, "the health check itself failed")
  expect_false(grepl("secret|abc123", r$content))
})

test_that("with_security_headers on top gives the answer the security headers too", {
  app <- with_security_headers(with_health_check(fake_app(), check = function() list(ok = TRUE, body = "ok")))
  r <- app$httpHandler(request("/health"))
  expect_equal(r$headers[["X-Frame-Options"]], "DENY")
  expect_equal(r$headers[["Cache-Control"]], "no-store")
})

# ---- the cache ----

test_that("repeated checks within a minute are answered from the cache", {
  rm(list = ls(health_cache), envir = health_cache)
  calls <- 0
  check <- function() { calls <<- calls + 1; list(ok = TRUE, body = "ok") }
  t0 <- as.POSIXct("2026-10-23 10:00:00", tz = "UTC")

  cached_health(check, now = t0)
  cached_health(check, now = t0 + 10)
  cached_health(check, now = t0 + 59)
  expect_equal(calls, 1)

  cached_health(check, now = t0 + 61)               # a minute later: ask again
  expect_equal(calls, 2)
})

test_that("the cache doesn't hide a change for longer than its age", {
  rm(list = ls(health_cache), envir = health_cache)
  state <- list(ok = TRUE, body = "ok")
  check <- function() state
  t0 <- as.POSIXct("2026-10-23 10:00:00", tz = "UTC")

  expect_true(cached_health(check, now = t0)$ok)
  state <- list(ok = FALSE, body = "degraded: serving the SQLite backup because Turso fails")
  expect_true(cached_health(check, now = t0 + 30)$ok)        # still the cached answer
  expect_false(cached_health(check, now = t0 + 90)$ok)       # the new one after a minute
})
