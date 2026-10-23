test_that("parse_turso_query_result parses a realistic pipeline response into a typed data frame", {
  fixture <- jsonlite::fromJSON(
    testthat::test_path("fixtures/turso_pipeline_response.json"),
    simplifyVector = FALSE
  )

  df <- parse_turso_query_result(fixture)

  expect_s3_class(df, "data.frame")
  expect_equal(names(df), c("id", "library_branch_name", "lat", "city_name"))
  expect_equal(nrow(df), 3)

  # Numeric columns should be coerced to numeric, not left as character
  expect_type(df$id, "integer")
  expect_type(df$lat, "double")
  expect_equal(df$id, c(84921L, 84878L, 85103L))
  expect_equal(df$library_branch_name[1], "Arabianrannan kirjasto")
  expect_equal(df$city_name, c("Helsinki", "Helsinki", "Pori"))

  # A NULL cell value should come through as NA, not crash or become "NULL"
  expect_true(is.na(df$lat[3]))
})

test_that("parse_turso_query_result returns an empty data frame when there are no results", {
  empty_result <- list(results = list())
  df <- parse_turso_query_result(empty_result)
  expect_s3_class(df, "data.frame")
  expect_equal(nrow(df), 0)
})

test_that("parse_turso_query_result returns a column-named empty data frame when a query matches zero rows", {
  zero_row_result <- list(
    results = list(
      list(
        response = list(
          result = list(
            cols = list(list(name = "id"), list(name = "city_name")),
            rows = list()
          )
        )
      )
    )
  )
  df <- parse_turso_query_result(zero_row_result)
  expect_equal(names(df), c("id", "city_name"))
  expect_equal(nrow(df), 0)
})

test_that("parse_turso_query_result raises an error when the query itself failed", {
  error_result <- list(
    results = list(
      list(error = list(message = "no such table: libraries"))
    )
  )
  expect_error(parse_turso_query_result(error_result), "no such table: libraries")
})

test_that("parse_turso_query_result raises an error on a top-level pipeline error", {
  error_result <- list(error = list(message = "invalid baton"))
  expect_error(parse_turso_query_result(error_result), "invalid baton")
})

# ---- reads give up and try once more ----
# httr2's mocked responses skip retrying, so the test looks at the policy that
# is set on the request (the retry itself was tried against a real local
# server by hand).

test_that("a read has a timeout and is tried once more after a transient error", {
  req <- build_turso_read_request("https://example.turso.io", "token", list(requests = list()))
  expect_equal(req$options$timeout_ms, turso_read_timeout * 1000)
  expect_equal(req$policies$retry_max_tries, 2)
  expect_true(req$policies$retry_on_failure)
  expect_equal(req$policies$retry_backoff(1), turso_retry_wait)
  expect_match(req$url, "/v2/pipeline$")
})

test_that("turso_query goes through that request", {
  withr::local_envvar(TURSO_DATABASE_URL = "libsql://example.turso.io", TURSO_AUTH_TOKEN = "t")
  seen <- NULL
  httr2::with_mocked_responses(
    function(req) {
      seen <<- req
      httr2::response_json(body = jsonlite::fromJSON(
        testthat::test_path("fixtures/turso_pipeline_response.json"), simplifyVector = FALSE))
    },
    df <- turso_query("SELECT 1")
  )
  expect_equal(seen$options$timeout_ms, turso_read_timeout * 1000)
  expect_equal(seen$policies$retry_max_tries, 2)
  expect_equal(nrow(df), 3)
})
