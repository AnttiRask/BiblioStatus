# The functions that draw the map (app/www/functions.R). They work on a plain
# leaflet map, so the calls they add can be inspected without a browser.

lib <- function(ids, status = "Open") {
  data.frame(
    id = ids, library_branch_name = paste("Library", ids),
    lat = 60 + ids / 10, lon = 24 + ids / 10, city_name = "Helsinki",
    library_url = NA_character_, library_address = "Street 1",
    open_status = status, opening_hours = "09:00 - 20:00",
    stringsAsFactors = FALSE
  )
}
methods_of <- function(map) vapply(map$x$calls, function(x) x$method, character(1))
# On a plain widget leaflet keeps the view in map$x (as calls when it is a proxy)
view_of <- function(map) {
  if (!is.null(map$x$fitBounds)) "fitBounds"
  else if (!is.null(map$x$setView)) "setView"
  else "none"
}
as_json <- function(map) as.character(jsonlite::toJSON(map$x$calls, auto_unbox = TRUE, null = "null", force = TRUE))

test_that("refresh_map replaces tiles, markers and legend, in that order", {
  map <- refresh_map(leaflet::leaflet(), lib(1:5), dark = FALSE, fit = TRUE)
  calls <- methods_of(map)
  expect_equal(sum(calls == "addTiles"), 2)               # base + labels
  expect_equal(calls[calls != "addTiles"][1:4], c("clearMarkers", "clearControls", "addCircleMarkers", "addLegend"))
})

test_that("with fit = TRUE many libraries are fitted into view, few are centred", {
  expect_equal(view_of(refresh_map(leaflet::leaflet(), lib(1:5))), "fitBounds")
  expect_equal(view_of(refresh_map(leaflet::leaflet(), lib(1:SINGLE_LIBRARY_ZOOM_THRESHOLD))), "setView")
})

test_that("with fit = FALSE the view is left alone", {
  expect_equal(view_of(refresh_map(leaflet::leaflet(), lib(1:5), fit = FALSE)), "none")
})

test_that("light and dark use their own tiles and marker colours", {
  light <- refresh_map(leaflet::leaflet(), lib(1:3), dark = FALSE)
  dark  <- refresh_map(leaflet::leaflet(), lib(1:3), dark = TRUE)
  expect_match(as_json(light), "World_Light_Gray_Base", fixed = TRUE)
  expect_match(as_json(light), light_colors$Open, fixed = TRUE)
  expect_false(grepl("World_Dark_Gray", as_json(light), fixed = TRUE))
  expect_match(as_json(dark), "World_Dark_Gray_Base", fixed = TRUE)
  expect_match(as_json(dark), dark_colors$Open, fixed = TRUE)
  expect_false(grepl("World_Light_Gray", as_json(dark), fixed = TRUE))
})

test_that("the basemap layers have fixed ids, so a proxy replaces them instead of stacking", {
  json <- as_json(refresh_map(leaflet::leaflet(), lib(1:3)))
  expect_match(json, "basemap", fixed = TRUE)
  expect_match(json, "labels", fixed = TRUE)
})

test_that("every library gets a marker with its id, and the legend lists all five colours", {
  map <- refresh_map(leaflet::leaflet(), lib(c(7, 8, 9)))
  markers <- map$x$calls[[which(methods_of(map) == "addCircleMarkers")]]
  expect_equal(markers$args[[4]], c(7, 8, 9))               # layerId
  legend <- map$x$calls[[which(methods_of(map) == "addLegend")]]
  expect_length(legend$args[[1]]$colors, 5)
  expect_equal(as.character(legend$args[[1]]$labels)[5], txt$legend_unknown)
})

test_that("closed libraries get a dashed border, open ones a solid one", {
  mixed <- rbind(lib(1, "Open"), lib(2, "Closed"))
  json <- as_json(refresh_map(leaflet::leaflet(), mixed))
  expect_match(json, "4, 3", fixed = TRUE)
  expect_false(grepl("4, 3", as_json(refresh_map(leaflet::leaflet(), lib(1:3, "Open"))), fixed = TRUE))
})

test_that("phones get bigger markers and no hover labels", {
  marker_call <- function(map) map$x$calls[[which(methods_of(map) == "addCircleMarkers")]]
  desktop <- marker_call(refresh_map(leaflet::leaflet(), lib(1:3), mobile = FALSE))
  phone   <- marker_call(refresh_map(leaflet::leaflet(), lib(1:3), mobile = TRUE))

  expect_equal(desktop$args[[3]], DESKTOP_MARKER_RADIUS)    # radius
  expect_equal(phone$args[[3]], MOBILE_MARKER_RADIUS)
  expect_gt(MOBILE_MARKER_RADIUS, DESKTOP_MARKER_RADIUS)
  expect_equal(desktop$args[[11]], paste("Library", 1:3))   # hover label
  expect_null(phone$args[[11]])
})

test_that("map_options turns off accidental zooms on phones only", {
  expect_equal(map_options(TRUE)$doubleClickZoom, FALSE)
  expect_null(map_options(FALSE)$doubleClickZoom)
})

# ---- coordinates that can't be in Finland ----
# The data once had a library at 0, 0 (off the coast of Africa): fitting the
# view to every library zoomed the all-cities map out to half the world.

test_that("plausible_location accepts Finland, including Åland and Utsjoki, and refuses the rest", {
  expect_true(plausible_location(60.17, 24.94))     # Helsinki
  expect_true(plausible_location(60.10, 19.94))     # Mariehamn
  expect_true(plausible_location(69.91, 27.01))     # Utsjoki
  expect_false(plausible_location(0, 0))
  expect_false(plausible_location(NA, 24))
  expect_false(plausible_location(60, NA))
  expect_false(plausible_location(59.4, 24.7))      # Tallinn
  expect_false(plausible_location(55.7, 12.6))      # Copenhagen
  expect_equal(plausible_location(c(60, 0, NA), c(24, 0, 24)), c(TRUE, FALSE, FALSE))
})

test_that("one library with wrong coordinates doesn't decide where the map looks", {
  libs <- rbind(lib(1:5), transform(lib(6), lat = 0, lon = 0))
  map <- refresh_map(leaflet::leaflet(), libs, fit = TRUE)
  bounds <- map$x$fitBounds
  expect_equal(unlist(bounds[1:4]), c(60.1, 24.1, 60.5, 24.5))   # south, west, north, east of libraries 1-5
})

test_that("a single library with wrong coordinates leaves the view alone", {
  map <- refresh_map(leaflet::leaflet(), transform(lib(1), lat = 0, lon = 0), fit = TRUE)
  expect_equal(view_of(map), "none")
})

test_that("the view is still set for libraries that do have coordinates", {
  expect_equal(view_of(refresh_map(leaflet::leaflet(), lib(1), fit = TRUE)), "setView")
  expect_equal(view_of(refresh_map(leaflet::leaflet(), lib(1:5), fit = TRUE)), "fitBounds")
})
