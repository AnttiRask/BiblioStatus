# Connect to SQLite
db_path <- here("libraries.sqlite")

# Uncomment for the local version
# db_path <- here("app/libraries.sqlite")

# Function to fetch libraries from SQLite
fetch_libraries <- function() {
  # fmt: skip
  con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
  libraries <- dbReadTable(con, "libraries")
  dbDisconnect(con)

  return(libraries)
}

# Function to fetch schedules from SQLite and determine the current open status
fetch_schedules <- function() {
  # fmt: skip
  con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
  schedules <- dbReadTable(con, "schedules")
  dbDisconnect(con)

  return(schedules)
}
