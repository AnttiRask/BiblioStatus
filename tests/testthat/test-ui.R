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

# ---- the light/dark switch (our own button, as in the other apps) ----

test_that("the page has our own light/dark button and not bslib's switch", {
  html <- page_html()
  expect_match(html, 'id="mode-toggle"', fixed = TRUE)
  expect_false(grepl("bslib-input-dark-mode", html, fixed = TRUE))
  # the script is in the head, which as.character(ui) leaves out
  ui <- withr::with_dir(here::here("app"), source("ui.R", local = TRUE)$value)
  head <- paste(as.character(htmltools::renderTags(ui)$head), collapse = "\n")
  expect_match(head, '<script src="mode-toggle.js?v=', fixed = TRUE)    # not just a mention in a comment
})

test_that("the button has a sun and a moon, and a label that names the mode a click switches to", {
  button <- as.character(mode_toggle_button())
  expect_match(button, "biblio-icon-sun", fixed = TRUE)
  expect_match(button, "biblio-icon-moon", fixed = TRUE)
  # light is the default, so the first label says dark
  expect_match(button, paste0('aria-label="', txt$mode_to_dark, '"'), fixed = TRUE)
  expect_match(button, paste0('data-label-to-light="', txt$mode_to_light, '"'), fixed = TRUE)
  expect_match(button, paste0('data-label-to-dark="', txt$mode_to_dark, '"'), fixed = TRUE)
  expect_match(button, 'type="button"', fixed = TRUE)
  expect_match(button, 'aria-hidden="true"', fixed = TRUE)         # the icons are decoration, the label speaks
  expect_false(identical(txt$mode_to_light, txt$mode_to_dark))
})

test_that("the button's text comes from txt", {
  with_marked_strings <- function(env = parent.frame()) {
    original <- get("txt", envir = globalenv())
    assign("txt", stats::setNames(as.list(paste0("[", names(original), "]")), names(original)), envir = globalenv())
    withr::defer(assign("txt", original, envir = globalenv()), envir = env)
  }
  with_marked_strings()
  button <- as.character(mode_toggle_button())
  expect_match(button, "[mode_to_dark]", fixed = TRUE)
  expect_match(button, "[mode_to_light]", fixed = TRUE)
})

test_that("the script and the styles agree with the button on names and on what the server reads", {
  js <- paste(readLines(here::here("app", "www", "mode-toggle.js")), collapse = "\n")
  css <- paste(readLines(here::here("app", "www", "styles.css")), collapse = "\n")
  # the id and the data attributes the button carries
  expect_match(js, 'getElementById("mode-toggle")', fixed = TRUE)
  expect_match(js, "data-label-to-light", fixed = TRUE)
  expect_match(js, "data-label-to-dark", fixed = TRUE)
  # (there is no JavaScript runner in the tests: these pin the lines that matter, and
  # the behaviour was checked in a real browser: icon, label, theme, server input,
  # map tiles, statistics chart, and a reconnect while dark)
  # a click flips the mode, and the label names the mode the NEXT click switches to
  expect_match(js, 'root.setAttribute("data-bs-theme", isDark() ? "light" : "dark");', fixed = TRUE)
  expect_match(js, 'button.getAttribute(isDark() ? "data-label-to-light" : "data-label-to-dark")', fixed = TRUE)
  # light first, and the server's input: "dark" / "light", also after a reconnect
  expect_match(js, 'setAttribute("data-bs-theme", "light")', fixed = TRUE)
  expect_match(js, 'Shiny.setInputValue("dark_mode", isDark() ? "dark" : "light")', fixed = TRUE)
  expect_match(js, "shiny:connected", fixed = TRUE)
  # the icons swap by theme
  expect_match(css, '[data-bs-theme="dark"] .biblio-icon-sun { display: block; }', fixed = TRUE)
  expect_match(css, '[data-bs-theme="dark"] .biblio-icon-moon { display: none; }', fixed = TRUE)
  expect_match(css, ".biblio-icon-sun { display: none; }", fixed = TRUE)
})
