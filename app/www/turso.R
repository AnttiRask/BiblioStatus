# Turso Database Wrapper for Shiny App
# Simplified read-only version for app use

library(httr2)
library(jsonlite)

# Convert libsql:// URL to https:// for HTTP API
convert_to_https <- function(url) {
  if (grepl("^libsql://", url)) {
    return(sub("^libsql://", "https://", url))
  }
  return(url)
}

# Execute a SELECT query and return results as data frame
# Note: This version uses pre-loaded credentials from environment or secret.R
turso_query <- function(sql, params = list()) {
  # Get credentials (should be loaded by functions.R)
  url <- Sys.getenv("TURSO_DATABASE_URL")
  token <- Sys.getenv("TURSO_AUTH_TOKEN")

  # Fallback to global variables if set
  if (url == "" && exists("TURSO_DATABASE_URL", envir = .GlobalEnv)) {
    url <- get("TURSO_DATABASE_URL", envir = .GlobalEnv)
    token <- get("TURSO_AUTH_TOKEN", envir = .GlobalEnv)
  }

  if (url == "" || token == "") {
    stop("Turso credentials not available")
  }

  https_url <- convert_to_https(url)

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
        Authorization = paste("Bearer", token),
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
  df <- do.call(rbind, lapply(rows, function(row) {
    values <- lapply(row, function(cell) {
      if (is.null(cell$value)) NA else cell$value
    })
    as.data.frame(values, stringsAsFactors = FALSE)
  }))

  colnames(df) <- cols
  return(df)
}
