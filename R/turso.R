# Turso Database Helper Functions for BiblioStatus
# Uses httr2 package to interact with Turso HTTP API

library(httr2)
library(jsonlite)

# Convert libsql:// URL to https:// for HTTP API
convert_to_https <- function(url) {
  if (grepl("^libsql://", url)) {
    return(sub("^libsql://", "https://", url))
  }
  return(url)
}

# Load Turso credentials from environment or secret.R
load_turso_credentials <- function() {
  url <- Sys.getenv("TURSO_DATABASE_URL")
  token <- Sys.getenv("TURSO_AUTH_TOKEN")

  # If not in environment, try loading from secret.R. Resolved via here() so
  # this works regardless of the caller's working directory (repo root for
  # standalone scripts, app/ for the Shiny app itself).
  if (url == "" || token == "") {
    secret_file <- if (file.exists(here::here("secret.R"))) {
      here::here("secret.R")
    } else if (file.exists(here::here("app", "secret.R"))) {
      here::here("app", "secret.R")
    } else {
      NULL
    }

    if (!is.null(secret_file)) {
      source(secret_file, local = TRUE)
      url <- get0("TURSO_DATABASE_URL", ifnotfound = url)
      token <- get0("TURSO_AUTH_TOKEN", ifnotfound = token)
    }
  }

  if (url == "" || token == "") {
    stop("Turso credentials not found. Set TURSO_DATABASE_URL and TURSO_AUTH_TOKEN environment variables or create secret.R file.")
  }

  list(url = url, token = token)
}

# Execute a SELECT query and return results as data frame
turso_query <- function(sql, params = list()) {
  creds <- load_turso_credentials()
  https_url <- convert_to_https(creds$url)

  # Build request body for Turso HTTP API
  request_body <- list(requests = list(build_execute_request(sql, params)))

  # Make HTTP request to Turso pipeline endpoint
  response <- tryCatch({
    request(paste0(https_url, "/v2/pipeline")) %>%
      req_headers(
        Authorization = paste("Bearer", creds$token),
        `Content-Type` = "application/json"
      ) %>%
      req_body_json(request_body) %>%
      req_perform()
  }, error = function(e) {
    stop("Turso query failed: ", conditionMessage(e))
  })

  # Parse response
  result <- resp_body_json(response, simplifyVector = FALSE)

  parse_turso_query_result(result)
}

# Parse a decoded /v2/pipeline response body into a data frame.
# Split out from turso_query() so the parsing logic can be unit-tested
# against fixture JSON without making a live HTTP call.
parse_turso_query_result <- function(result) {
  # Check for errors
  if (!is.null(result$error)) {
    stop("Turso query error: ", result$error$message)
  }

  # Extract results from first request
  if (length(result$results) == 0) {
    return(data.frame())
  }

  query_result <- result$results[[1]]

  # Check for query-specific errors
  if (!is.null(query_result$error)) {
    stop("Turso query error: ", query_result$error$message)
  }

  # Extract column names and rows
  if (is.null(query_result$response$result$cols) ||
      is.null(query_result$response$result$rows)) {
    return(data.frame())
  }

  cols <- sapply(query_result$response$result$cols, function(c) c$name)
  rows <- query_result$response$result$rows

  if (length(rows) == 0) {
    # Return empty data frame with column names
    df <- as.data.frame(matrix(nrow = 0, ncol = length(cols)))
    colnames(df) <- cols
    return(df)
  }

  # Convert rows to data frame
  # Build a list of vectors (one per row), then convert to data frame
  rows_list <- lapply(rows, function(row) {
    sapply(row, function(cell) {
      if (is.null(cell) || is.null(cell$value)) NA else cell$value
    })
  })

  # Convert to data frame with proper column names
  df <- as.data.frame(do.call(rbind, rows_list), stringsAsFactors = FALSE)
  colnames(df) <- cols

  # Convert columns from character to appropriate types
  df[] <- lapply(df, function(x) type.convert(as.character(x), as.is = TRUE))

  return(df)
}

# Encode a single statement's bind parameters into the Turso HTTP API's arg
# shape. Shared by turso_query(), turso_execute(), and turso_execute_batch().
build_turso_args <- function(params) {
  if (length(params) == 0) return(list())
  lapply(params, function(p) {
    # Handle NULL and NA values
    if (is.null(p) || (length(p) == 1 && is.na(p))) {
      list(type = "null")
    } else {
      list(type = "text", value = as.character(p))
    }
  })
}

# Build one "execute" request entry for the /v2/pipeline requests array.
build_execute_request <- function(sql, params = list()) {
  list(
    type = "execute",
    stmt = list(
      sql = sql,
      args = build_turso_args(params)
    )
  )
}

# Execute an INSERT/UPDATE/DELETE statement
turso_execute <- function(sql, params = list()) {
  creds <- load_turso_credentials()
  https_url <- convert_to_https(creds$url)

  request_body <- list(requests = list(build_execute_request(sql, params)))

  # Make HTTP request
  response <- tryCatch({
    request(paste0(https_url, "/v2/pipeline")) %>%
      req_headers(
        Authorization = paste("Bearer", creds$token),
        `Content-Type` = "application/json"
      ) %>%
      req_body_json(request_body) %>%
      req_perform()
  }, error = function(e) {
    stop("Turso execute failed: ", conditionMessage(e))
  })

  # Parse response
  result <- resp_body_json(response, simplifyVector = FALSE)

  # Check for errors
  if (!is.null(result$error)) {
    stop("Turso execute error: ", result$error$message)
  }

  # Check query-specific errors
  if (length(result$results) > 0 && !is.null(result$results[[1]]$error)) {
    stop("Turso execute error: ", result$results[[1]]$error$message)
  }

  # Return number of rows affected
  if (length(result$results) > 0 &&
      !is.null(result$results[[1]]$response$result$affected_row_count)) {
    return(result$results[[1]]$response$result$affected_row_count)
  }

  return(invisible(NULL))
}

# Execute many INSERT/UPDATE/DELETE statements in as few HTTP round-trips as
# possible, using Turso's /v2/pipeline support for multiple statements per
# request. `statements` is a list of list(sql = ..., params = ...). Statements
# are chunked into groups of `batch_size` to stay within practical HTTP
# payload limits. Returns the total number of rows affected across all
# statements.
turso_execute_batch <- function(statements, batch_size = 200) {
  if (length(statements) == 0) return(invisible(0))

  creds <- load_turso_credentials()
  https_url <- convert_to_https(creds$url)

  total_affected <- 0
  chunks <- split(statements, ceiling(seq_along(statements) / batch_size))

  for (chunk in chunks) {
    request_body <- list(
      requests = lapply(chunk, function(stmt) {
        build_execute_request(stmt$sql, stmt$params)
      })
    )

    response <- tryCatch({
      request(paste0(https_url, "/v2/pipeline")) %>%
        req_headers(
          Authorization = paste("Bearer", creds$token),
          `Content-Type` = "application/json"
        ) %>%
        req_body_json(request_body) %>%
        req_perform()
    }, error = function(e) {
      stop("Turso batch execute failed: ", conditionMessage(e))
    })

    result <- resp_body_json(response, simplifyVector = FALSE)

    if (!is.null(result$error)) {
      stop("Turso batch execute error: ", result$error$message)
    }

    # Check each statement's own result for a per-statement error, and sum
    # affected row counts. Report which statement (1-indexed within the
    # chunk) failed, since a bare error for a 200-statement batch would
    # otherwise be very hard to debug.
    for (i in seq_along(result$results)) {
      stmt_result <- result$results[[i]]
      if (!is.null(stmt_result$error)) {
        stop(sprintf(
          "Turso batch execute error on statement %d of %d: %s",
          i, length(chunk), stmt_result$error$message
        ))
      }
      affected <- stmt_result$response$result$affected_row_count
      if (!is.null(affected)) {
        total_affected <- total_affected + affected
      }
    }
  }

  total_affected
}
