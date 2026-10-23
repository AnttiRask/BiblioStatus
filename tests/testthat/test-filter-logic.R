# Tests for app/www/filter_logic.R: the dropdown rules, with no Shiny in them.
#
# Fixture: 3 cities, 6 libraries. Services:
#   Sauna:  1 (Helsinki), 3 (Espoo)
#   Kirjakahvila: 1, 2 (Helsinki), 4 (Tampere)
#   Pelit:  4 (Tampere)
fl <- data.frame(
  id = c(1, 2, 3, 4, 5, 100000),
  library_branch_name = c("Oodi", "Pasila", "Entresse", "Metso", "Ylä", "Äänekoski"),
  city_name = c("Helsinki", "Helsinki", "Espoo", "Tampere", "Tampere", "Äänekoski"),
  stringsAsFactors = FALSE
)
fs <- data.frame(
  library_id = c(1, 3, 1, 2, 4, 4),
  service_name = c("Sauna", "Sauna", "Kirjakahvila", "Kirjakahvila", "Kirjakahvila", "Pelit"),
  stringsAsFactors = FALSE
)
sel <- function(city = "", service = "", library = "") list(city = city, service = service, library = library)
ids <- function(x) sort(x$id)

test_that("normalize_selection fills in missing, NULL and NA fields", {
  expect_equal(normalize_selection(list()), sel())
  expect_equal(normalize_selection(list(city = NULL, service = NA, library = 5)), sel(library = "5"))
})

test_that("filter_libraries applies each filter and combines them", {
  expect_equal(ids(filter_libraries(fl, fs, sel())), c(1, 2, 3, 4, 5, 100000))
  expect_equal(ids(filter_libraries(fl, fs, sel(city = "Helsinki"))), c(1, 2))
  expect_equal(ids(filter_libraries(fl, fs, sel(service = "Sauna"))), c(1, 3))
  expect_equal(ids(filter_libraries(fl, fs, sel(city = "Helsinki", service = "Sauna"))), 1)
  expect_equal(ids(filter_libraries(fl, fs, sel(library = "4"))), 4)
  expect_equal(nrow(filter_libraries(fl, fs, sel(city = "Espoo", service = "Pelit"))), 0)
})

test_that("filter_libraries can skip fields, and ids of 100000 or more match as text", {
  expect_equal(ids(filter_libraries(fl, fs, sel(city = "Espoo", service = "Sauna"), ignore = "city")), c(1, 3))
  expect_equal(ids(filter_libraries(fl, fs, sel(library = "100000"))), 100000)
  expect_equal(id_text(100000), "100000")
})

test_that("the city list is always complete, and the service list depends on the city only", {
  all_cities <- c("Espoo", "Helsinki", "Tampere", "\u00c4\u00e4nekoski")
  expect_equal(filter_options(fl, fs, sel())$cities$value, all_cities)

  # neither a service nor a library narrows the city list
  o <- filter_options(fl, fs, sel(service = "Sauna"))
  expect_equal(o$cities$value, all_cities)
  expect_equal(o$cities$n, c(1, 2, 2, 1))          # all libraries of each city
  expect_equal(filter_options(fl, fs, sel(library = "1"))$cities$value, all_cities)

  # the service list follows the city
  o <- filter_options(fl, fs, sel(city = "Tampere"))
  expect_equal(o$services$value, c("Kirjakahvila", "Pelit"))
  expect_equal(o$services$label, c("Kirjakahvila (1)", "Pelit (1)"))

  # a picked library doesn't narrow the service list either
  o <- filter_options(fl, fs, sel(library = "1"))
  expect_equal(o$services$value, c("Kirjakahvila", "Pelit", "Sauna"))
})

test_that("the library list depends on the city and the service", {
  expect_setequal(filter_options(fl, fs, sel())$libraries$value, c("1", "2", "3", "4", "5", "100000"))
  o <- filter_options(fl, fs, sel(city = "Helsinki", service = "Kirjakahvila"))
  expect_setequal(o$libraries$value, c("1", "2"))
  expect_equal(filter_options(fl, fs, sel(city = "Espoo", service = "Sauna"))$libraries$label, "Entresse")
  # labels are the library names, sorted the Finnish way
  expect_equal(filter_options(fl, fs, sel(city = "Helsinki"))$libraries$label, c("Oodi", "Pasila"))
})

test_that("lists are sorted the Finnish way and counts match the libraries", {
  o <- filter_options(fl, fs, sel())
  expect_equal(o$cities$value, c("Espoo", "Helsinki", "Tampere", "Äänekoski"))  # Ä after Z in Finnish
  expect_equal(o$cities$label[o$cities$value == "Helsinki"], "Helsinki (2)")
  expect_equal(o$services$n[o$services$value == "Kirjakahvila"], 3)
})

test_that("as_choices puts the all-entry first and can leave the counts out", {
  o <- filter_options(fl, fs, sel())
  with_counts <- as_choices(o$cities, "All Cities")
  expect_equal(unname(with_counts[1]), "")
  expect_equal(names(with_counts)[1:2], c("All Cities", "Espoo (1)"))
  expect_equal(names(as_choices(o$cities, "All Cities", counts = FALSE))[2], "Espoo")
})

test_that("picking a service keeps a library that offers it", {
  r <- apply_filter_change(fl, fs, sel(city = "Helsinki", library = "1"), "service", "Sauna")
  expect_true(r$changed)
  expect_equal(r$sel, sel(city = "Helsinki", service = "Sauna", library = "1"))
  expect_null(r$notice)
})

test_that("picking a service the library doesn't offer clears the library with a notice", {
  r <- apply_filter_change(fl, fs, sel(city = "Helsinki", library = "2"), "service", "Sauna")
  expect_true(r$changed)
  expect_equal(r$sel, sel(city = "Helsinki", service = "Sauna"))
  expect_equal(r$notice, "Library cleared: it does not offer Sauna")
})

test_that("picking a city the library isn't in clears the library with a notice", {
  r <- apply_filter_change(fl, fs, sel(city = "Helsinki", library = "1"), "city", "Espoo")
  expect_equal(r$sel, sel(city = "Espoo"))
  expect_equal(r$notice, "Library cleared: it is not in Espoo")
})

test_that("picking a library sets its city and nothing else", {
  r <- apply_filter_change(fl, fs, sel(service = "Kirjakahvila"), "library", "4")
  expect_equal(r$sel, sel(city = "Tampere", service = "Kirjakahvila", library = "4"))
  expect_null(r$notice)
})

test_that("clearing a filter changes only that filter", {
  start <- sel(city = "Helsinki", service = "Sauna", library = "1")
  expect_equal(apply_filter_change(fl, fs, start, "city", "")$sel, sel(service = "Sauna", library = "1"))
  expect_equal(apply_filter_change(fl, fs, start, "service", "")$sel, sel(city = "Helsinki", library = "1"))
  expect_equal(apply_filter_change(fl, fs, start, "library", "")$sel, sel(city = "Helsinki", service = "Sauna"))
})

test_that("the browser echoing a value we already have is a no-op", {
  start <- sel(city = "Helsinki", library = "1")
  r <- apply_filter_change(fl, fs, start, "city", "Helsinki")
  expect_false(r$changed)
  expect_equal(r$sel, start)
  expect_false(apply_filter_change(fl, fs, start, "service", "")$changed)
})

test_that("a value that isn't offered is rejected without touching the selection", {
  start <- sel(service = "Pelit")
  r <- apply_filter_change(fl, fs, start, "library", "1")   # library 1 doesn't offer Pelit
  expect_false(r$changed)
  expect_equal(r$sel, start)
  expect_false(apply_filter_change(fl, fs, sel(), "library", "999")$changed)
  expect_false(apply_filter_change(fl, fs, sel(city = "Helsinki"), "service", "Pelit")$changed)
})

test_that("a city the selected service isn't offered in clears the service with a notice", {
  r <- apply_filter_change(fl, fs, sel(city = "Helsinki", service = "Kirjakahvila"), "city", "Espoo")
  expect_true(r$changed)
  expect_equal(r$sel, sel(city = "Espoo"))
  expect_equal(r$notice, "Service cleared: it is not offered in Espoo")

  # without a city selected the same happens
  r <- apply_filter_change(fl, fs, sel(service = "Sauna"), "city", "Tampere")
  expect_equal(r$sel, sel(city = "Tampere"))
  expect_equal(r$notice, "Service cleared: it is not offered in Tampere")
})

test_that("a city that offers the selected service keeps it", {
  r <- apply_filter_change(fl, fs, sel(city = "Helsinki", service = "Kirjakahvila"), "city", "Tampere")
  expect_equal(r$sel, sel(city = "Tampere", service = "Kirjakahvila"))
  expect_null(r$notice)
})

test_that("a city that matches neither the library nor the service clears both, and says so", {
  r <- apply_filter_change(fl, fs, sel(city = "Helsinki", service = "Sauna", library = "1"), "city", "Tampere")
  expect_equal(r$sel, sel(city = "Tampere"))
  expect_equal(r$notice, "Library cleared: it is not in Tampere. Service cleared: it is not offered in Tampere")
})

test_that("random changes keep every selection valid, and every offered choice gives a map", {
  set.seed(42)
  state <- sel()
  fields <- c("city", "service", "library")
  offered <- function(st, field) {
    facet <- c(city = "cities", service = "services", library = "libraries")[[field]]
    filter_options(fl, fs, st)[[facet]]$value
  }

  for (step in 1:120) {
    field <- sample(fields, 1)
    choices <- c("", offered(state, field))
    value <- sample(choices, 1)

    # every offered choice leads to at least one library on the map
    r <- apply_filter_change(fl, fs, state, field, value)
    expect_gt(nrow(filter_libraries(fl, fs, r$sel)), 0)

    # and the new selection is among the choices the lists offer
    for (f in c("city", "service", "library")) {
      if (nzchar(r$sel[[f]])) expect_true(r$sel[[f]] %in% offered(r$sel, f), info = paste(step, f))
    }
    state <- r$sel
  }
})
