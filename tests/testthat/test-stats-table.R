# The service table on the statistics tab. With DT's default (server = TRUE) every
# page, sort and search is a request to a URL that belongs to the Shiny session;
# once the session has ended (a page left open for an hour, or across a deploy)
# that URL answers 404 and DataTables shows an "Ajax error" alert. The table is
# sent to the page once instead, and the browser does the paging and sorting.

stats_libs <- data.frame(id = 1:3, city_name = c("Helsinki", "Helsinki", "Tampere"), stringsAsFactors = FALSE)
stats_services <- data.frame(
  library_id = c(1, 2, 3, 1, 2),
  service_name = c("Sauna", "Sauna", "Sauna", "Printing", "Yoga"),
  stringsAsFactors = FALSE
)

widget_of <- function(output_value) {
  # what the browser gets: the widget's JSON, with its options and data
  json <- if (is.character(output_value)) output_value else jsonlite::toJSON(output_value, auto_unbox = TRUE, null = "null", force = TRUE)
  jsonlite::fromJSON(as.character(json), simplifyVector = FALSE)
}

test_that("the service table is sent to the page whole and not fetched page by page", {
  testServer(
    service_stats_server,
    args = list(library_services = reactive(stats_services), libraries = reactive(stats_libs), dark_mode = reactive(FALSE)),
    {
      session$flushReact()
      w <- widget_of(output$service_table)
      expect_null(w$x$options$serverSide %||% NULL)             # not server-side (an absent option is the default FALSE)
      expect_false(isTRUE(w$x$options$serverSide))
      expect_null(w$x$options$ajax)                             # no data URL tied to the session
      # the rows of the table are in the page: three services, counted over three libraries
      expect_length(w$x$data[[2]], 3)                           # column "Service Name"
      expect_setequal(unlist(w$x$data[[2]]), c("Sauna", "Printing", "Yoga"))
      expect_equal(unlist(w$x$data[[3]])[unlist(w$x$data[[2]]) == "Sauna"], 3)
    }
  )
})

test_that("the table keeps its paging and ordering options", {
  testServer(
    service_stats_server,
    args = list(library_services = reactive(stats_services), libraries = reactive(stats_libs), dark_mode = reactive(FALSE)),
    {
      session$flushReact()
      options <- widget_of(output$service_table)$x$options
      expect_equal(options$pageLength, 20)
      expect_true(options$searching)
      expect_true(options$ordering)
    }
  )
})

test_that("the source has server = FALSE on the table (so a change can't quietly bring the ajax URL back)", {
  src <- paste(readLines(here::here("app", "modules", "service_stats.R")), collapse = "\n")
  expect_match(src, "}, server = FALSE, options = list(", fixed = TRUE)
})
