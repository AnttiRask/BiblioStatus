# The page theme and the colours the CSS uses: the page and the map must be in the
# same mode (light page with the light map, dark page with the dark map).

test_that("the light mode of the page is light and the dark mode is the brand dark", {
  theme <- app_theme()
  vars <- bslib::bs_get_variables(theme, c("body-bg", "body-color", "body-bg-dark", "link-color-dark", "primary"))

  # light mode: a light background, not the dark brand colour (the old bug)
  expect_false(identical(toupper(vars[["body-bg"]]), toupper(brand_colours$dark_bg)))
  expect_match(vars[["body-bg"]], "^#?(fff|ffffff|FFF|FFFFFF)$|white", ignore.case = TRUE)

  # dark mode: the brand dark background, and a lighter red for links
  expect_equal(toupper(vars[["body-bg-dark"]]), toupper(brand_colours$dark_bg))
  expect_equal(toupper(vars[["link-color-dark"]]), toupper(brand_colours$red_on_dark))
  expect_equal(toupper(vars[["primary"]]), toupper(brand_colours$red))
})

test_that("the app starts in light mode, like the map", {
  # ui.R is read from the app folder, the way Shiny does (it uses relative paths)
  env <- new.env(parent = globalenv())
  withr::with_dir(here::here("app"), source("ui.R", local = env))
  html <- paste(as.character(env$ui), collapse = "\n")
  # the toggle component carries the starting mode
  expect_match(html, '<bslib-input-dark-mode id="dark_mode"[^>]*mode="light"')
  expect_false(grepl('<bslib-input-dark-mode[^>]*mode="dark"', html))
})

test_that("the CSS accent colour matches the brand colours in both modes", {
  css <- paste(readLines(here::here("app/www/styles.css"), warn = FALSE), collapse = "\n")
  light <- sub(".*:root \\{\\s*--brand-accent: *([#0-9A-Fa-f]+);.*", "\\1", css)
  dark  <- sub(".*\\[data-bs-theme=\"dark\"\\] \\{\\s*--brand-accent: *([#0-9A-Fa-f]+);.*", "\\1", css)
  expect_equal(toupper(light), toupper(brand_colours$red))
  expect_equal(toupper(dark), toupper(brand_colours$red_on_dark))
})

test_that("the CSS has no colours that only work on a dark page", {
  css <- paste(readLines(here::here("app/www/styles.css"), warn = FALSE), collapse = "\n")
  expect_false(grepl("#1DB954|#168d40", css, ignore.case = TRUE))        # leftover Spotify green links
  expect_false(grepl("background-color: #1a1a1a", css, ignore.case = TRUE))  # fixed dark sidebar
  # the loading text follows the theme instead of being white
  loading <- regmatches(css, regexpr("\\.loading-text \\{[^}]*\\}", css))
  expect_match(loading, "var\\(--bs-body-color\\)")
})
