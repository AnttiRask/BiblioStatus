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

  return(schedules)
}
