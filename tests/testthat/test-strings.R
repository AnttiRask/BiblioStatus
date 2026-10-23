# The user-facing text lives in strings.R (txt). These tests check that the
# popups, the schedule list and the service statistics module take it from there
# (so a translation only has to replace the list), and that no text of txt
# is written out again in the code.

# Replace txt for the calling test: every value becomes "[key]", so any text that
# is still written in the code stands out
with_marked_strings <- function(env = parent.frame()) {
  original <- get("txt", envir = globalenv())
  marked <- stats::setNames(as.list(paste0("[", names(original), "]")), names(original))
  assign("txt", marked, envir = globalenv())
  withr::defer(assign("txt", original, envir = globalenv()), envir = env)
  invisible(marked)
}

popup_args <- list("https://example.fi", "Oodi", "Street 1", "Open", 60.17, 24.94)

test_that("the map popup takes its labels from txt", {
  with_marked_strings()
  main <- do.call(build_library_popup, c(popup_args, list(opening_hours = "08:00 - 20:00")))
  expect_match(main, "[popup_status]", fixed = TRUE)
  expect_match(main, "[popup_hours]", fixed = TRUE)
  expect_match(main, "[popup_directions]", fixed = TRUE)

  unknown <- do.call(build_library_popup, c(popup_args, list(opening_hours = NA_character_)))
  expect_match(unknown, "[popup_hours_none]", fixed = TRUE)

  nearby <- do.call(build_library_popup, c(popup_args, list(distance_display = "1.2 km")))
  expect_match(nearby, "[popup_distance]", fixed = TRUE)
  expect_false(grepl("Hours", nearby))
})

test_that("the popup labels are escaped, so a translation can't break the HTML", {
  original <- get("txt", envir = globalenv())
  changed <- original
  changed$popup_directions <- "Reitti <script>"
  assign("txt", changed, envir = globalenv())
  withr::defer(assign("txt", original, envir = globalenv()))
  html <- do.call(build_library_popup, c(popup_args, list(opening_hours = "08:00 - 20:00")))
  expect_false(grepl("<script>", html, fixed = TRUE))
  expect_match(html, "Reitti &lt;script&gt;", fixed = TRUE)
})

test_that("the schedule list takes its marker and its empty message from txt", {
  with_marked_strings()
  schedules <- data.frame(library_id = 1, date = "2026-10-24", from = "08:00", to = "20:00",
                          status_label = "Open", stringsAsFactors = FALSE)
  expect_match(format_schedule_periods(1, schedules, "10:00"), "[schedule_now]", fixed = TRUE)
  expect_equal(format_schedule_periods(2, schedules, "10:00"), "[no_schedule]")
})

test_that("the service statistics page takes its text from txt", {
  with_marked_strings()
  html <- as.character(service_stats_ui("stats"))
  for (key in c("stats_heading", "stats_intro", "stats_city_label", "stats_top_heading",
                "stats_all_heading", "all_cities")) {
    expect_match(html, paste0("[", key, "]"), fixed = TRUE)
  }
})

test_that("the chart title and the table headings come from txt", {
  with_marked_strings()
  expect_equal(stats_chart_title("all"), "[stats_title_all]")
  expect_equal(stats_chart_title(NULL), "[stats_title_all]")

  expect_equal(
    names(stats_table(data.frame(service_name = "Sauna", library_count = 3L))),
    c("[stats_col_service]", "[stats_col_count]")
  )
})

test_that("the chart title names the city", {
  expect_equal(stats_chart_title("Espoo"), "Most Common Services in Espoo")
  expect_equal(stats_chart_title("all"), "Most Common Library Services (All Cities)")
})

test_that("the table keeps its data and only renames the columns", {
  counts <- data.frame(service_name = c("Sauna", "Yoga"), library_count = c(3L, 1L), stringsAsFactors = FALSE)
  out <- stats_table(counts)
  expect_equal(names(out), c("Service Name", "Libraries Offering"))
  expect_equal(out[[1]], c("Sauna", "Yoga"))
  expect_equal(out[[2]], c(3L, 1L))
})

test_that("app.js gets its messages from txt", {
  expect_equal(client_config$messages$geolocationUnsupported, txt$geolocation_unsupported)
  expect_equal(client_config$messages$geolocationDenied, txt$geolocation_denied)
  expect_equal(client_config$messages$geolocationFailed, txt$geolocation_failed)
  expect_equal(client_config$startupTimeoutMs, geo_config$startupTimeoutMs)   # the timings are still there

  js <- paste(readLines(here::here("app", "www", "app.js")), collapse = "\n")
  expect_match(js, "BIBLIO_CONFIG.messages.geolocationDenied", fixed = TRUE)
  expect_false(grepl("Please enable location", js, fixed = TRUE))
})

# Guard: a text that is in txt must not be written out again in the code.
# (The status labels such as "Closed for the whole day" are data values the code
# compares against, and have a legend_ entry for the legend only.)
test_that("no text of txt is written out again in the code", {
  code_files <- c(
    here::here("app", c("ui.R", "server.R")),
    list.files(here::here("app", "server"), "\\.R$", full.names = TRUE),
    list.files(here::here("app", "modules"), "\\.R$", full.names = TRUE),
    here::here("app", "www", c("functions.R", "filter_logic.R", "data_layer.R", "app.js"))
  )
  code <- unlist(lapply(code_files, readLines, warn = FALSE))
  code <- code[!grepl("^\\s*(#|//)", code)]

  values <- unlist(txt[!startsWith(names(txt), "legend_")])
  values <- values[nchar(values) >= 8 & !grepl("%", values, fixed = TRUE)]
  for (value in unique(values)) {
    expect_false(
      any(grepl(trimws(value), code, fixed = TRUE)),
      info = paste("written out again in the code:", value)
    )
  }
})
