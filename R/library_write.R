# How the weekly job replaces the libraries and their services in Turso, planned
# as ONE transaction (turso_execute_atomic()): a reader sees the old libraries and
# services until the commit, then the new ones. The first version deleted both
# tables and then inserted row by row in separate requests; the libraries were
# missing for about 17 seconds and the services for four minutes, and every page
# loaded then had no libraries, or no services in the service dropdown (seen on
# 2026-10-24). No Turso or file access here, so it can be tested on its own
# (test-library-write.R).

# INSERT statements for the rows of `data`, many rows per statement (one
# statement per row took minutes; Turso runs a statement in about 20 ms).
# Returns a list of list(sql, params), with the parameters row by row.
multi_row_insert <- function(table, columns, data, rows_per_statement = 100) {
  n <- nrow(data)
  if (n == 0) return(list())
  starts <- seq(1, n, by = rows_per_statement)
  lapply(starts, function(start) {
    rows <- start:min(start + rows_per_statement - 1, n)
    one_row <- paste0("(", paste(rep("?", length(columns)), collapse = ", "), ")")
    list(
      sql = sprintf(
        "INSERT INTO %s (%s) VALUES %s",
        table, paste(columns, collapse = ", "), paste(rep(one_row, length(rows)), collapse = ", ")
      ),
      params = unlist(lapply(rows, function(i) lapply(columns, function(col) data[[col]][i])), recursive = FALSE)
    )
  })
}

library_columns <- c("id", "library_branch_name", "lat", "lon", "city_name",
                     "library_url", "library_phone", "library_email", "library_address")
service_columns <- c("library_id", "service_name")

# Everything that replaces the libraries and services, in the order the
# foreign key needs: the services go first, the services come back last.
library_replace_statements <- function(libraries, library_services, rows_per_statement = 100) {
  c(
    list(list(sql = "DELETE FROM library_services", params = list())),
    list(list(sql = "DELETE FROM libraries", params = list())),
    multi_row_insert("libraries", library_columns, libraries, rows_per_statement),
    multi_row_insert("library_services", service_columns, library_services, rows_per_statement)
  )
}

# TRUE if a fetch of `new_count` libraries can replace `old_count` stored ones.
# "Delete everything, insert what the API returned" is a fine transaction when the
# API returned nothing, and would commit an empty database: refuse a fetch with
# fewer than `min_share` of the libraries already stored. An unknown old count
# (the read failed) can't be judged and is let through if the new one isn't empty.
library_fetch_looks_complete <- function(new_count, old_count, min_share = 0.5) {
  if (is.na(new_count) || new_count == 0) return(FALSE)
  if (is.na(old_count) || old_count == 0) return(TRUE)
  new_count >= min_share * old_count
}
