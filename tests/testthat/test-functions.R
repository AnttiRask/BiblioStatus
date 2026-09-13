test_that("calculate_distance returns 0 for identical points", {
  expect_equal(calculate_distance(60.1699, 24.9384, 60.1699, 24.9384), 0)
})

test_that("calculate_distance matches known real-world distance", {
  # Helsinki (60.1699, 24.9384) to Tampere (61.4978, 23.7610) is ~160km great-circle
  d <- calculate_distance(60.1699, 24.9384, 61.4978, 23.7610)
  expect_gt(d, 150)
  expect_lt(d, 170)
})

test_that("calculate_distances_to_libraries adds distance_km and distance_display columns", {
  library_data <- data.frame(
    id = c(1, 2),
    lat = c(60.1699, 61.4978),
    lon = c(24.9384, 23.7610),
    stringsAsFactors = FALSE
  )

  result <- calculate_distances_to_libraries(60.1699, 24.9384, library_data)

  expect_true(all(c("distance_km", "distance_display") %in% names(result)))
  expect_equal(result$distance_km[1], 0)
  expect_match(result$distance_display[1], "^0\\.0 km$")
  expect_match(result$distance_display[2], "^[0-9]+\\.[0-9] km$")
})

test_that("format_schedule_periods returns a message when no schedule exists", {
  empty_schedules <- data.frame(
    library_id = integer(0), from = character(0), to = character(0),
    status_label = character(0), stringsAsFactors = FALSE
  )

  result <- format_schedule_periods(1, empty_schedules, "10:00")
  expect_equal(result, "No schedule information available")
})

test_that("format_schedule_periods marks the current period and formats others plainly", {
  schedules <- data.frame(
    library_id = c(1, 1),
    from = c("09:00", "18:00"),
    to = c("17:00", "20:00"),
    status_label = c("Open", "Self-service"),
    stringsAsFactors = FALSE
  )

  result <- format_schedule_periods(1, schedules, "10:00")

  expect_match(result, "<strong>09:00-17:00 \\(Open\\) ← now</strong>", fixed = FALSE)
  expect_match(result, "<li>18:00-20:00 \\(Self-service\\)</li>", fixed = FALSE)
  expect_false(grepl("18:00-20:00.*← now", result))
})

test_that("format_schedule_periods filters to only the requested library_id", {
  schedules <- data.frame(
    library_id = c(1, 2),
    from = c("09:00", "09:00"),
    to = c("17:00", "17:00"),
    status_label = c("Open", "Open"),
    stringsAsFactors = FALSE
  )

  result <- format_schedule_periods(2, schedules, "10:00")
  expect_equal(lengths(regmatches(result, gregexpr("<li>", result))), 1)
})
