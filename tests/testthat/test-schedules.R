# Tests for R/schedules.R, against saved responses of the Kirkanta schedules API
# (7 days, library 84750 with opening periods every day, library 84751 closed on
# Saturday and Sunday). No network access.

source(here::here("R/schedules.R"))

read_fixture <- function(name) {
  paste(readLines(here::here("tests/testthat/fixtures", name), warn = FALSE), collapse = "\n")
}
week <- as.character(seq(as.Date("2026-10-23"), by = "day", length.out = 7))

test_that("helsinki_today is the Finnish date, not the server's", {
  # 22:30 UTC on the 23rd is 01:30 on the 24th in Finland (summer time ended on
  # 25 October 2026, so it is UTC+3 until then)
  expect_equal(helsinki_today(as.POSIXct("2026-10-23 22:30:00", tz = "UTC")), as.Date("2026-10-24"))
  expect_equal(helsinki_today(as.POSIXct("2026-10-23 05:55:00", tz = "UTC")), as.Date("2026-10-23"))
  # after the clocks go back (UTC+2) the cut-off moves an hour
  expect_equal(helsinki_today(as.POSIXct("2026-11-10 21:30:00", tz = "UTC")), as.Date("2026-11-10"))
  expect_equal(helsinki_today(as.POSIXct("2026-11-10 22:30:00", tz = "UTC")), as.Date("2026-11-11"))
})

test_that("schedule_window is a week of consecutive dates as text, starting today", {
  w <- schedule_window(as.Date("2026-10-29"))
  expect_equal(length(w), 7)
  expect_equal(w[c(1, 7)], c("2026-10-29", "2026-11-04"))   # crosses a month end
  expect_type(w, "character")
})

test_that("a week of opening periods becomes one row per period", {
  rows <- parse_schedule_response(read_fixture("kirkanta_schedules_open.json"), 84750, week)

  expect_named(rows, c("library_id", "date", "from_time", "to_time", "status_label"))
  expect_equal(nrow(rows), 3 * 1 + 4 * 3)               # 3 days with one period, 4 days with three
  expect_setequal(unique(rows$date), week)
  expect_true(all(rows$library_id == 84750))

  first_day <- rows[rows$date == "2026-10-23", ]
  expect_equal(first_day$from_time, "08:00")
  expect_equal(first_day$to_time, "18:00")
  expect_equal(first_day$status_label, "Self-service")   # status 2

  split_day <- rows[rows$date == "2026-10-26", ]
  expect_equal(split_day$from_time, c("08:00", "12:00", "15:00"))
  expect_equal(split_day$status_label, c("Self-service", "Open", "Self-service"))   # 2, 1, 2
})

test_that("closed days become one 'Closed for the whole day' row without times", {
  rows <- parse_schedule_response(read_fixture("kirkanta_schedules_closed_days.json"), 84751, week)
  weekend <- rows[rows$date %in% c("2026-10-24", "2026-10-25"), ]

  expect_equal(nrow(weekend), 2)
  expect_equal(weekend$status_label, rep("Closed for the whole day", 2))
  expect_true(all(is.na(weekend$from_time)) && all(is.na(weekend$to_time)))
})

test_that("only the wanted dates are kept", {
  rows <- parse_schedule_response(read_fixture("kirkanta_schedules_open.json"), 84750, week[1:2])
  expect_setequal(unique(rows$date), week[1:2])
})

test_that("dates the API didn't answer for get an 'Unknown' row, so every date has a row", {
  # the fixture covers 23 to 29 October; ask for two more days
  longer <- as.character(seq(as.Date("2026-10-23"), by = "day", length.out = 9))
  rows <- parse_schedule_response(read_fixture("kirkanta_schedules_open.json"), 84750, longer)
  extra <- rows[rows$date %in% longer[8:9], ]
  expect_equal(extra$status_label, c("Unknown", "Unknown"))
  expect_setequal(unique(rows$date), longer)
})

test_that("an empty or failed response gives an 'Unknown' row for every date", {
  expect_equal(nrow(parse_schedule_items(NULL, 1, week)), 7)
  expect_equal(unique(parse_schedule_items(NULL, 1, week)$status_label), "Unknown")
  empty <- parse_schedule_response('{"items": []}', 1, week)
  expect_equal(nrow(empty), 7)
  expect_equal(unique(empty$status_label), "Unknown")
})

test_that("a day without usable times is 'Unknown', not an error", {
  json <- '{"items": [{"library": 1, "date": "2026-10-23", "closed": false, "times": []}]}'
  rows <- parse_schedule_response(json, 1, week[1])
  expect_equal(nrow(rows), 1)
  expect_equal(rows$status_label, "Unknown")
})

test_that("unknown status numbers are 'Unknown' and 0 is a temporary closure", {
  expect_equal(schedule_status_label(c(0, 1, 2, 7, NA)),
    c("Temporarily closed", "Open", "Self-service", "Unknown", "Unknown"))
})
