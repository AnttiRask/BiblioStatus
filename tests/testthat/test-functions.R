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

test_that("map_tile_urls gives a base and a labels layer per theme, in Esri's z/y/x order", {
  light <- map_tile_urls(FALSE)
  dark <- map_tile_urls(TRUE)
  expect_named(light, c("base", "labels"))
  expect_true(endsWith(light$base, "World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}"))
  expect_true(endsWith(light$labels, "World_Light_Gray_Reference/MapServer/tile/{z}/{y}/{x}"))
  expect_match(dark$base, "World_Dark_Gray_Base/", fixed = TRUE)
  expect_match(dark$labels, "World_Dark_Gray_Reference/", fixed = TRUE)
  # no API key in any URL, and everything comes from the one host
  expect_false(any(grepl("key=", c(unlist(light), unlist(dark)))))
  expect_true(all(startsWith(c(unlist(light), unlist(dark)), map_tiles_host)))
})

test_that("add_basemap adds a base layer with the attribution and a labels layer without", {
  calls <- leaflet::leaflet()$x$calls
  expect_length(calls, 0)

  tiles <- Filter(
    function(x) x$method == "addTiles",
    add_basemap(leaflet::leaflet(), FALSE)$x$calls
  )
  expect_length(tiles, 2)
  base <- tiles[[1]]$args
  labels <- tiles[[2]]$args

  expect_equal(base[[2]], "basemap")
  expect_equal(labels[[2]], "labels")
  # The regression: the attribution was lost when passed through tileOptions()
  expect_equal(base[[4]]$attribution, map_attribution)
  expect_match(base[[4]]$attribution, "Esri", fixed = TRUE)
  expect_match(base[[4]]$attribution, "OpenStreetMap", fixed = TRUE)
  expect_null(labels[[4]]$attribution)
  # requests are capped at the last real zoom, closer views are scaled up
  expect_equal(base[[4]]$maxNativeZoom, map_tile_max_native_zoom)
  expect_equal(labels[[4]]$maxNativeZoom, map_tile_max_native_zoom)
  expect_equal(base[[4]]$maxZoom, map_max_zoom)
  expect_gte(map_max_zoom, map_tile_max_native_zoom)
})

test_that("add_basemap switches both layers for dark mode", {
  tiles <- Filter(
    function(x) x$method == "addTiles",
    add_basemap(leaflet::leaflet(), TRUE)$x$calls
  )
  expect_match(tiles[[1]]$args[[1]], "World_Dark_Gray_Base", fixed = TRUE)
  expect_match(tiles[[2]]$args[[1]], "World_Dark_Gray_Reference", fixed = TRUE)
})

test_that("build_library_popup escapes text and URLs from the data", {
  html <- build_library_popup(
    library_url = "https://x.example/?a=1&b='><script>alert(1)</script>",
    library_branch_name = "<img src=x onerror=alert(1)>",
    library_address = "Katu 1 <b>",
    open_status = "Open", lat = 60.17, lon = 24.94,
    opening_hours = "8-20"
  )
  expect_false(grepl("<script>|<img|<b>\\s*$", html))
  expect_match(html, "&lt;img src=x onerror=alert\\(1\\)&gt;")
  expect_match(html, "rel='noopener noreferrer'", fixed = TRUE)
  expect_match(html, "Katu 1 &lt;b&gt;", fixed = TRUE)
})
