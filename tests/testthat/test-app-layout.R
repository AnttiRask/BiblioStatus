# Shiny serves everything in app/www/ to anyone who asks for it (the browser needs
# app.js and the styles from there). The R code must not be in it: until 2026-11-03
# functions.R, security.R, health.R and the rest could be downloaded from the live site.

test_that("no R file is served from app/www", {
  served <- list.files(here::here("app", "www"), recursive = TRUE, all.files = TRUE)
  expect_false(any(grepl("\\.[Rr]$", served)))
  expect_true(all(c("app.js", "styles.css", "mode-toggle.js") %in% served))   # the guard looks at the right folder
})

test_that("the R code Shiny loads is where global.R and run.R say", {
  for (f in c("functions", "variables", "strings", "data_layer", "filter_logic", "health", "security")) {
    expect_true(file.exists(here::here("app", "lib", paste0(f, ".R"))), info = f)
  }
})
