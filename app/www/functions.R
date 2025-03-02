# Connect to DuckDB
db_path <- "libraries.duckdb"

# Function to fetch libraries from DuckDB
fetch_libraries <- function() {
  # fmt: skip
  con       <- dbConnect(duckdb(), dbdir = db_path, read_only = TRUE)
  libraries <- dbReadTable(con, "libraries")
  dbDisconnect(con)
  return(libraries)
}

# Function to fetch schedules from DuckDB and determine the current open status
fetch_schedules <- function() {
  # fmt: skip
  con       <- dbConnect(duckdb(), dbdir = db_path, read_only = TRUE)
  schedules <- dbReadTable(con, "schedules")
  dbDisconnect(con)

  now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")

  schedules <- schedules %>%
    mutate(
      is_open_now = from <= now & to >= now,
      # fmt: skip
      open_status = case_when(
        status_label               == "Closed for the whole day" ~ "Closed for the whole day",
        is_open_now & status_label == "Open" ~ "Open",
        is_open_now & status_label == "Self-service" ~ "Self-service",
        is_open_now & status_label == "Temporarily closed" ~ "Temporarily closed",
        TRUE ~ "Closed"
      ),
      opening_hours = if_else(
        is_open_now,
        paste0(from, " - ", to),
        NA_character_
      )
    )

  return(schedules)
}
