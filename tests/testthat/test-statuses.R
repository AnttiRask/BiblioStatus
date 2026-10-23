# compute_library_statuses() and friends (app/www/functions.R): a library's status
# from its schedule rows and the clock. Recomputed every minute by the app.

st_libs <- data.frame(
  id = 1:5, library_branch_name = paste("Library", 1:5), city_name = "Helsinki",
  stringsAsFactors = FALSE
)
row <- function(library_id, date, from, to, status_label) {
  data.frame(library_id = library_id, date = date, from = from, to = to,
    status_label = status_label, stringsAsFactors = FALSE)
}
st_rows <- rbind(
  # library 1: three periods today
  row(1, "2026-10-23", "09:00", "12:00", "Self-service"),
  row(1, "2026-10-23", "12:00", "15:00", "Open"),
  row(1, "2026-10-23", "15:00", "18:00", "Self-service"),
  # library 2: closed all day today, open tomorrow
  row(2, "2026-10-23", NA, NA, "Closed for the whole day"),
  row(2, "2026-10-24", "09:00", "17:00", "Open"),
  # library 3: one period today, an early one tomorrow
  row(3, "2026-10-23", "10:00", "20:00", "Open"),
  row(3, "2026-10-24", "07:00", "08:00", "Open"),
  # library 4: no rows at all
  # library 5: temporarily closed in the morning
  row(5, "2026-10-23", "08:00", "09:00", "Temporarily closed")
)
at <- function(now, today = "2026-10-23") compute_library_statuses(st_libs, st_rows, today, now)
status_of <- function(result, id) result$open_status[result$id == id]
hours_of <- function(result, id) result$opening_hours[result$id == id]

test_that("a period that is on now gives its status and its opening hours", {
  r <- at("10:30")
  expect_equal(status_of(r, 1), "Self-service")
  expect_equal(hours_of(r, 1), "09:00 - 12:00")
  expect_equal(status_of(r, 3), "Open")
  expect_equal(hours_of(r, 3), "10:00 - 20:00")
})

test_that("outside the opening periods a library is Closed, without opening hours", {
  r <- at("08:30")
  expect_equal(status_of(r, 3), "Closed")         # opens at 10:00
  expect_true(is.na(hours_of(r, 3)))
  expect_equal(status_of(at("21:00"), 3), "Closed")
})

test_that("both ends of a period count (the minute it opens and the minute it closes)", {
  expect_equal(status_of(at("10:00"), 3), "Open")
  expect_equal(status_of(at("20:00"), 3), "Open")
  expect_equal(status_of(at("20:01"), 3), "Closed")
  expect_equal(status_of(at("09:59"), 3), "Closed")
})

test_that("when two periods touch, the one that ends last decides", {
  r <- at("12:00")                                 # the end of 09-12 and the start of 12-15
  expect_equal(status_of(r, 1), "Open")
  expect_equal(hours_of(r, 1), "12:00 - 15:00")
})

test_that("a status moves on as the clock does: the stale-status case", {
  # library 3 opens at 10:00: at 09:59 it's closed, a minute later open
  expect_equal(status_of(at("09:59"), 3), "Closed")
  expect_equal(status_of(at("10:00"), 3), "Open")
  # library 1 changes from self-service to open to self-service to closed
  expect_equal(vapply(c("11:00", "13:00", "16:00", "18:30"), function(t) status_of(at(t), 1), character(1), USE.NAMES = FALSE),
    c("Self-service", "Open", "Self-service", "Closed"))
})

test_that("a closed day stays closed whatever the time", {
  expect_equal(status_of(at("03:00"), 2), "Closed for the whole day")
  expect_equal(status_of(at("13:00"), 2), "Closed for the whole day")
  expect_true(is.na(hours_of(at("13:00"), 2)))
})

test_that("a temporary closure shows while its period is on, and is just Closed otherwise", {
  expect_equal(status_of(at("08:30"), 5), "Temporarily closed")
  expect_equal(status_of(at("12:00"), 5), "Closed")
})

test_that("a library without schedule rows has no status", {
  r <- at("12:00")
  expect_true(is.na(status_of(r, 4)))
  expect_true(is.na(hours_of(r, 4)))
})

test_that("only the rows of the given day count, so the day can roll over", {
  today <- at("07:30")                              # 23 October
  tomorrow <- at("07:30", today = "2026-10-24")
  expect_equal(status_of(today, 3), "Closed")       # today library 3 opens at 10:00
  expect_equal(status_of(tomorrow, 3), "Open")      # tomorrow it is open 07-08
  expect_equal(status_of(tomorrow, 2), "Closed")    # tomorrow library 2 is open 09-17, not yet
  expect_true(is.na(status_of(tomorrow, 1)))        # library 1 has no rows tomorrow
})

test_that("every library appears once, in its order, with its own columns", {
  r <- at("12:00")
  expect_equal(r$id, st_libs$id)
  expect_true(all(names(st_libs) %in% names(r)))
})

test_that("todays_schedules keeps one day's rows and marks the period that is on now", {
  day <- todays_schedules(st_rows, "2026-10-23", "13:00")
  expect_equal(unique(day$date), "2026-10-23")
  expect_equal(day$is_open_now[day$library_id == 1], c(FALSE, TRUE, FALSE))
  expect_equal(nrow(todays_schedules(st_rows, "2030-01-01", "13:00")), 0)
})

test_that("the Finnish clock is HH:MM text, which compares in time order", {
  expect_match(helsinki_time_now(), "^[0-2][0-9]:[0-5][0-9]$")
  expect_true("09:05" < "10:00" && "10:00" < "23:59")
})

test_that("the page loads today and tomorrow, across a month end too", {
  expect_equal(schedule_dates_to_load(as.Date("2026-10-23")), c("2026-10-23", "2026-10-24"))
  expect_equal(schedule_dates_to_load(as.Date("2026-10-31")), c("2026-10-31", "2026-11-01"))
})

test_that("the check is timed for just after the next full minute", {
  t <- function(s) as.POSIXct(s, tz = "UTC")
  expect_equal(ms_to_next_minute(t("2026-10-23 10:00:30")), 30500)
  expect_equal(ms_to_next_minute(t("2026-10-23 10:00:00")), 60500)
  expect_equal(ms_to_next_minute(t("2026-10-23 10:00:59.9")), 1000)    # never faster than once a second
})
