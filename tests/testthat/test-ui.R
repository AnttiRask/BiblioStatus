# The page itself (ui.R), which the server tests don't render.

page_html <- function() {
  # ui.R finds www/styles.css relative to app/, as when Shiny runs it
  ui <- withr::with_dir(here::here("app"), source("ui.R", local = TRUE)$value)
  paste(as.character(ui), collapse = "\n")
}

test_that("the city dropdown can choose All Cities: the empty choice is allowed and named", {
  html <- page_html()
  # selectize's settings for the city dropdown sit in a JSON script next to the select
  start <- regexpr('id="city_filter"', html, fixed = TRUE)
  expect_gt(start, 0)
  city <- substr(html, start, start + 600)
  expect_match(city, '"allowEmptyOption":true', fixed = TRUE)
  expect_match(city, paste0('"placeholder":"', txt$all_cities, '"'), fixed = TRUE)
})

test_that("the three dropdowns and the search box are on the page", {
  html <- page_html()
  for (id in c("library_finder", "city_filter", "library_search", "service_filter")) {
    expect_match(html, paste0('id="', id, '"'), fixed = TRUE)
  }
})
