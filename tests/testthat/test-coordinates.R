# Which coordinates the pipeline believes (R/coordinates.R). The API once gave
# 0, 0 (off the coast of Africa) for a library, and that went straight into the
# database. Order: manual override, the API's if they can be in Finland, the
# last good ones from the snapshot, else nothing.

api <- function(...) data.frame(id = c(1, 2, 3, 4), lat = c(60.17, 60.20, 61.50, 62.40), lon = c(24.94, 25.00, 23.76, 22.17), ...)
table_of <- function(id, lat, lon) data.frame(id = id, lat = lat, lon = lon)
no_table <- table_of(numeric(), numeric(), numeric())

test_that("plausible_location accepts Finland, including Åland and Utsjoki, and refuses the rest", {
  expect_true(plausible_location(60.17, 24.94))     # Helsinki
  expect_true(plausible_location(60.10, 19.94))     # Mariehamn
  expect_true(plausible_location(69.91, 27.01))     # Utsjoki
  expect_false(plausible_location(0, 0))
  expect_false(plausible_location(NA, 24))
  expect_false(plausible_location(60, NA))
  expect_false(plausible_location(59.4, 24.7))      # Tallinn
  expect_equal(plausible_location(c(60, 0, NA), c(24, 0, 24)), c(TRUE, FALSE, FALSE))
})

test_that("good API coordinates are used as they are", {
  r <- resolve_coordinates(api(), no_table, no_table)
  expect_equal(r$source, rep("api", 4))
  expect_equal(r$lat, api()$lat)
  expect_equal(r$lon, api()$lon)
  expect_equal(r$id, 1:4)
})

test_that("0, 0 from the API is replaced by the snapshot's coordinates", {
  libs <- api(); libs$lat[3] <- 0; libs$lon[3] <- 0
  snapshot <- table_of(1:4, c(60.17, 60.20, 61.4983, 62.40), c(24.94, 25.00, 23.7609, 22.17))
  r <- resolve_coordinates(libs, no_table, snapshot)
  expect_equal(r$source, c("api", "api", "snapshot", "api"))
  expect_equal(c(r$lat[3], r$lon[3]), c(61.4983, 23.7609))
})

test_that("missing and outside-Finland coordinates are rescued the same way", {
  libs <- api(); libs$lat[1] <- NA; libs$lon[2] <- NA; libs$lat[3] <- 59.4; libs$lon[3] <- 24.7   # Tallinn
  snapshot <- table_of(1:3, c(60.17, 60.20, 61.50), c(24.94, 25.00, 23.76))
  r <- resolve_coordinates(libs, no_table, snapshot)
  expect_equal(r$source, c("snapshot", "snapshot", "snapshot", "api"))
  expect_equal(r$lat[1:3], c(60.17, 60.20, 61.50))
})

test_that("a library with nothing usable anywhere gets no coordinates, and is marked", {
  libs <- api(); libs$lat[2] <- 0; libs$lon[2] <- 0
  r <- resolve_coordinates(libs, no_table, no_table)
  expect_equal(r$source[2], "none")
  expect_true(is.na(r$lat[2]) && is.na(r$lon[2]))
  expect_equal(r$source[-2], rep("api", 3))
})

test_that("a snapshot value that can't be in Finland isn't used either", {
  libs <- api(); libs$lat[1] <- 0; libs$lon[1] <- 0
  r <- resolve_coordinates(libs, no_table, table_of(1, 0, 0))
  expect_equal(r$source[1], "none")
})

test_that("a manual override beats the API and the snapshot", {
  libs <- api()
  r <- resolve_coordinates(libs, table_of(2, 60.9999, 25.9999), table_of(2, 60.5, 25.5))
  expect_equal(r$source, c("api", "override", "api", "api"))
  expect_equal(c(r$lat[2], r$lon[2]), c(60.9999, 25.9999))
})

test_that("an override also covers a library the API has no coordinates for", {
  libs <- api(); libs$lat[4] <- NA; libs$lon[4] <- NA
  r <- resolve_coordinates(libs, table_of(4, 62.0, 22.0), no_table)
  expect_equal(r$source[4], "override")
  expect_equal(c(r$lat[4], r$lon[4]), c(62.0, 22.0))
})

test_that("the order of the libraries is kept, and libraries unknown to the tables are fine", {
  libs <- api()[c(4, 2, 1), ]
  r <- resolve_coordinates(libs, table_of(99, 60, 24), table_of(98, 60, 24))
  expect_equal(r$id, c(4, 2, 1))
  expect_equal(r$source, rep("api", 3))
})

# ---- the snapshot ----

test_that("the snapshot has every library that has coordinates, with its name, in id order", {
  libs <- data.frame(id = c(3, 1, 2), library_branch_name = c("C", "A", "B"), stringsAsFactors = FALSE)
  resolved <- data.frame(id = c(3, 1, 2), lat = c(61.123456789, 60.1, NA), lon = c(23.5, 24.5, NA),
                         source = c("api", "snapshot", "none"), stringsAsFactors = FALSE)
  s <- build_coordinate_snapshot(resolved, libs)
  expect_equal(s$id, c(1, 3))                          # id order, without the library that has none
  expect_equal(s$name, c("A", "C"))
  expect_equal(s$lat, c(60.1, 61.123457), tolerance = 0)   # six decimals, exactly
  expect_equal(names(s), c("id", "lat", "lon", "name"))
})

test_that("the snapshot file is only written when it would change", {
  path <- withr::local_tempfile(fileext = ".csv")
  s <- data.frame(id = 1:2, lat = c(60.1, 61.2), lon = c(24.1, 23.2), name = c("Äänekoski", "Oodi"), stringsAsFactors = FALSE)
  expect_true(write_coordinate_snapshot(s, path))        # first time: written
  expect_false(write_coordinate_snapshot(s, path))       # the same: left alone
  s$lat[2] <- 61.3
  expect_true(write_coordinate_snapshot(s, path))        # a change: written
  expect_equal(read_coordinate_snapshot(path), s)        # and it reads back, accents included
})

test_that("a missing snapshot file is an empty snapshot", {
  s <- read_coordinate_snapshot(file.path(tempdir(), "no-such-file.csv"))
  expect_equal(nrow(s), 0)
  expect_equal(names(s), c("id", "lat", "lon", "name"))
  r <- resolve_coordinates(api(), no_table, s)          # and the pipeline still works without one
  expect_equal(r$source, rep("api", 4))
})

test_that("a snapshot taken from a resolution gives the same coordinates back", {
  libs <- cbind(api(), library_branch_name = c("A", "B", "C", "D"))
  libs$lat[3] <- 0; libs$lon[3] <- 0
  snap1 <- table_of(1:4, c(60.17, 60.20, 61.50, 62.40), c(24.94, 25.00, 23.76, 22.17))
  resolved <- resolve_coordinates(libs, no_table, snap1)
  snap2 <- build_coordinate_snapshot(resolved, libs)
  expect_equal(snap2$lat, snap1$lat)                    # the rescued value stays in the snapshot
  expect_equal(snap2$lon, snap1$lon)
})

# ---- the committed files ----

test_that("the committed snapshot is well formed: unique ids, plausible coordinates, names", {
  s <- read_coordinate_snapshot(here::here("data", "library_coordinates.csv"))
  expect_gt(nrow(s), 700)
  expect_equal(names(s), c("id", "lat", "lon", "name"))
  expect_equal(anyDuplicated(s$id), 0)
  expect_true(all(plausible_location(s$lat, s$lon)))
  expect_true(all(nzchar(s$name)))
  expect_false(is.unsorted(s$id))
})

test_that("the manual overrides are plausible too", {
  o <- utils::read.csv(here::here("data", "library_coordinate_overrides.csv"), stringsAsFactors = FALSE)
  expect_true(all(plausible_location(o$lat, o$lon)))
})
