# nearest_open_libraries(): the open libraries closest to a point, optionally only
# those offering a service. A small map around a user at 60.17, 24.94 (central
# Helsinki); lat/lon differences are in hundredths of a degree, so the order is
# obvious: 1 is closest, then 2, 3, 4, 5.
lib_at <- function(id, d_lat, status = "Open", city = "Helsinki") {
  data.frame(
    id = id, library_branch_name = paste("Library", id), city_name = city,
    lat = 60.17 + d_lat, lon = 24.94, open_status = status,
    library_url = NA_character_, library_address = "x", opening_hours = "09:00 - 20:00",
    stringsAsFactors = FALSE
  )
}
near_libs <- rbind(
  lib_at(1, 0.01, "Open"),
  lib_at(2, 0.02, "Closed"),               # closer than 3, but closed
  lib_at(3, 0.03, "Self-service"),
  lib_at(4, 0.04, "Closed for the whole day"),
  lib_at(5, 0.05, "Open"),
  lib_at(6, 0.50, "Open", city = "Tampere") # far away
)
near_svcs <- data.frame(
  library_id = c(1, 3, 5, 6, 2),
  service_name = c("Sauna", "Sauna", "Pelit", "Sauna", "Sauna"),
  stringsAsFactors = FALSE
)
near <- function(n = 5, service = "") {
  nearest_open_libraries(near_libs, near_svcs, 60.17, 24.94, n = n, service = service)
}

test_that("without a service: the closest open libraries, closest first, with distances", {
  r <- near(n = 3)
  expect_equal(r$id, c(1, 3, 5))                   # 2 and 4 are closed
  expect_true(all(diff(r$distance_km) > 0))
  expect_true(all(grepl(" km$", r$distance_display)))
})

test_that("closed libraries never count, however near", {
  expect_false(any(c(2, 4) %in% near(n = 10)$id))
})

test_that("with a service: only libraries offering it", {
  r <- near(n = 5, service = "Sauna")
  expect_equal(r$id, c(1, 3, 6))                   # 5 has no sauna; 2 has one but is closed
})

test_that("with a service, the nearest one can be far away", {
  expect_equal(near(n = 1, service = "Pelit")$id, 5)
  expect_equal(near(n = 5, service = "Pelit")$id, 5)
})

test_that("the number returned is capped, and smaller when fewer qualify", {
  expect_equal(nrow(near(n = 2)), 2)
  expect_equal(nrow(near(n = 50)), 4)              # 1, 3, 5, 6
})

test_that("nothing qualifies: a zero-row result", {
  expect_equal(nrow(near(service = "Koirat sallittu")), 0)
  expect_equal(nrow(nearest_open_libraries(near_libs[near_libs$open_status == "Closed", ], near_svcs, 60.17, 24.94, 5)), 0)
})

test_that("an empty service string and NULL mean no service filter", {
  expect_equal(near(n = 4, service = "")$id, near(n = 4, service = NULL)$id)
})

test_that("the city and library filters don't apply: the nearest can be in another city", {
  # library 6 is in Tampere and is returned for a user in Helsinki
  expect_true(6 %in% near(n = 10, service = "Sauna")$id)
})
