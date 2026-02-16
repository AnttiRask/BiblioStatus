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

  # If not in environment, try loading from secret.R
  if (url == "" || token == "") {
    secret_file <- if (file.exists("secret.R")) {
      "secret.R"
    } else if (file.exists("app/secret.R")) {
      "app/secret.R"
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
  request_body <- list(
    requests = list(
      list(
        type = "execute",
        stmt = list(
          sql = sql,
          args = if (length(params) > 0) {
            lapply(params, function(p) {
              # Handle NULL and NA values
              if (is.null(p) || (length(p) == 1 && is.na(p))) {
                list(type = "null")
              } else {
                list(type = "text", value = as.character(p))
              }
            })
          } else {
            list()
          }
        )
      )
    )
  )

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

# Execute an INSERT/UPDATE/DELETE statement
turso_execute <- function(sql, params = list()) {
  creds <- load_turso_credentials()
  https_url <- convert_to_https(creds$url)

  # Build request body
  request_body <- list(
    requests = list(
      list(
        type = "execute",
        stmt = list(
          sql = sql,
          args = if (length(params) > 0) {
            lapply(params, function(p) {
              # Handle NULL and NA values
              if (is.null(p) || (length(p) == 1 && is.na(p))) {
                list(type = "null")
              } else {
                list(type = "text", value = as.character(p))
              }
            })
          } else {
            list()
          }
        )
      )
    )
  )

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
