# How the weekly job replaces the libraries and services (R/library_write.R).
# The first version deleted both tables and inserted row by row in separate
# requests: the libraries were missing for ~17 seconds and the services for four
# minutes (2026-10-24), and a page loaded then had none. Now it is ONE
# transaction. The invariant tested here: a reader sees the old data until the
# commit, and the new data after it, never something in between.

# Pipeline code: the app doesn't load it
source(here::here("R", "library_write.R"))

make_libraries <- function(ids, name = "Library", city = "Helsinki") {
  data.frame(
    id = ids, library_branch_name = paste(name, ids), lat = 60 + ids / 100, lon = 24 + ids / 100,
    city_name = city, library_url = ifelse(ids %% 2 == 0, NA_character_, paste0("https://example.fi/", ids)),
    library_phone = "02 623 4200", library_email = NA_character_, library_address = "Street 1, 00100, Helsinki",
    stringsAsFactors = FALSE
  )
}
make_services <- function(ids, services = c("Sauna", "Printing")) {
  tidyr::expand_grid(library_id = ids, service_name = services) |> as.data.frame()
}

# A database file with two connections: a writer and a reader (WAL: the reader
# sees a consistent snapshot while the writer is in a transaction, like Turso)
new_db <- function(env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".sqlite", .local_envir = env)
  writer <- DBI::dbConnect(RSQLite::SQLite(), path)
  DBI::dbExecute(writer, "PRAGMA journal_mode=WAL")
  DBI::dbExecute(writer, "CREATE TABLE libraries (id INTEGER PRIMARY KEY, library_branch_name TEXT, lat REAL, lon REAL,
                          city_name TEXT, library_url TEXT, library_phone TEXT, library_email TEXT, library_address TEXT)")
  DBI::dbExecute(writer, "CREATE TABLE library_services (library_id INTEGER, service_name TEXT,
                          FOREIGN KEY (library_id) REFERENCES libraries (id))")
  DBI::dbExecute(writer, "PRAGMA foreign_keys=ON")
  reader <- DBI::dbConnect(RSQLite::SQLite(), path)
  withr::defer({ DBI::dbDisconnect(writer); DBI::dbDisconnect(reader) }, envir = env)
  list(writer = writer, reader = reader)
}
store <- function(db, libraries, services) {
  DBI::dbWriteTable(db$writer, "libraries", libraries, append = TRUE)
  DBI::dbWriteTable(db$writer, "library_services", services, append = TRUE)
}
counts <- function(con) {
  c(libraries = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM libraries")$n,
    services = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM library_services")$n)
}
run_statement <- function(con, s) {
  if (length(s$params) == 0) DBI::dbExecute(con, s$sql) else DBI::dbExecute(con, s$sql, params = unname(s$params))
}

# ---- the statements ----

test_that("rows are inserted many to a statement, with all their values in order", {
  libs <- make_libraries(1:250)
  statements <- multi_row_insert("libraries", library_columns, libs, rows_per_statement = 100)
  expect_length(statements, 3)                                           # 100 + 100 + 50
  expect_equal(lengths(lapply(statements, `[[`, "params")), c(900, 900, 450))
  expect_match(statements[[1]]$sql, "^INSERT INTO libraries \\(id, library_branch_name, lat, lon, city_name, library_url, library_phone, library_email, library_address\\) VALUES \\(\\?, ")
  expect_equal(lengths(regmatches(statements[[3]]$sql, gregexpr("\\(\\?", statements[[3]]$sql))), 50)   # 50 value tuples in the last one
  # the parameters are row after row, column after column
  expect_equal(statements[[1]]$params[[1]], 1)
  expect_equal(statements[[1]]$params[[2]], "Library 1")
  expect_equal(statements[[1]]$params[[10]], 2)
  expect_true(is.na(statements[[1]]$params[[15]]))                       # library 2 has no url: an NA, kept as NA
})

test_that("a statement's placeholders always match its parameters", {
  for (s in multi_row_insert("libraries", library_columns, make_libraries(1:233), 100)) {
    expect_equal(lengths(regmatches(s$sql, gregexpr("\\?", s$sql))), length(s$params))
  }
  for (s in multi_row_insert("library_services", service_columns, make_services(1:77), 50)) {
    expect_equal(lengths(regmatches(s$sql, gregexpr("\\?", s$sql))), length(s$params))
  }
})

test_that("no rows, no statements", {
  expect_length(multi_row_insert("libraries", library_columns, make_libraries(1)[0, ]), 0)
})

test_that("the replacement deletes the services first, then the libraries, then inserts libraries before services", {
  s <- library_replace_statements(make_libraries(1:5), make_services(1:5))
  sql <- vapply(s, function(x) x$sql, "")
  expect_equal(sql[1:2], c("DELETE FROM library_services", "DELETE FROM libraries"))
  expect_true(all(grepl("^INSERT INTO libraries", sql[3])))
  expect_true(all(grepl("^INSERT INTO library_services", sql[4])))
  expect_length(s, 4)
})

test_that("the real data fits in a few dozen statements, not twelve thousand", {
  s <- library_replace_statements(make_libraries(1:719), make_services(1:719, paste("S", 1:16)))   # 11,504 service rows
  expect_lt(length(s), 150)
})

# ---- the transaction ----

test_that("the replacement gives exactly the new libraries and services", {
  db <- new_db()
  store(db, make_libraries(1:5, name = "Old"), make_services(1:5))
  new <- make_libraries(3:9, name = "New")
  services <- make_services(3:9, c("Sauna", "Yoga", "Scanning"))
  DBI::dbWithTransaction(db$writer, for (s in library_replace_statements(new, services)) run_statement(db$writer, s))

  expect_equal(counts(db$reader), c(libraries = 7, services = 21))
  stored <- DBI::dbGetQuery(db$reader, "SELECT * FROM libraries ORDER BY id")
  expect_equal(stored$library_branch_name, paste("New", 3:9))
  expect_equal(stored$lat, 60 + (3:9) / 100)
  expect_true(is.na(stored$library_url[stored$id == 4]))                  # NULLs stay NULLs
  expect_equal(stored$library_url[stored$id == 3], "https://example.fi/3")
})

test_that("a reader sees the old data all through the write, and the new data after the commit", {
  db <- new_db()
  store(db, make_libraries(1:5, name = "Old"), make_services(1:5))
  before <- counts(db$reader)
  statements <- library_replace_statements(make_libraries(1:8, name = "New"), make_services(1:8, c("A", "B", "C")), rows_per_statement = 3)
  expect_gt(length(statements), 5)

  DBI::dbBegin(db$writer)
  for (s in statements) {
    run_statement(db$writer, s)
    expect_equal(counts(db$reader), before)       # after every statement: still the old, complete data
  }
  DBI::dbCommit(db$writer)

  expect_equal(counts(db$reader), c(libraries = 8, services = 24))
  expect_equal(DBI::dbGetQuery(db$reader, "SELECT DISTINCT substr(library_branch_name, 1, 3) AS p FROM libraries")$p, "New")
})

test_that("the old way (separate steps) does leave a window with nothing", {
  db <- new_db()
  store(db, make_libraries(1:5), make_services(1:5))
  DBI::dbExecute(db$writer, "DELETE FROM library_services")
  DBI::dbExecute(db$writer, "DELETE FROM libraries")
  expect_equal(counts(db$reader), c(libraries = 0, services = 0))          # what the page saw for minutes
})

test_that("a failure in the middle leaves the old data untouched", {
  db <- new_db()
  store(db, make_libraries(1:5, name = "Old"), make_services(1:5))
  before <- counts(db$reader)
  statements <- library_replace_statements(make_libraries(1:8, name = "New"), make_services(1:8), rows_per_statement = 3)
  statements[[length(statements) - 1]]$sql <- "INSERT INTO no_such_table VALUES (1)"

  expect_error(DBI::dbWithTransaction(db$writer, for (s in statements) run_statement(db$writer, s)))
  expect_equal(counts(db$reader), before)
  expect_equal(DBI::dbGetQuery(db$reader, "SELECT DISTINCT substr(library_branch_name, 1, 3) AS p FROM libraries")$p, "Old")
})

test_that("a service of a library that isn't there is refused, and nothing changes", {
  db <- new_db()
  store(db, make_libraries(1:3, name = "Old"), make_services(1:3))
  before <- counts(db$reader)
  statements <- library_replace_statements(make_libraries(1:3, name = "New"), make_services(c(1:3, 99)))
  expect_error(DBI::dbWithTransaction(db$writer, for (s in statements) run_statement(db$writer, s)))
  expect_equal(counts(db$reader), before)
})

# ---- a fetch that looks broken ----

test_that("a fetch with far fewer libraries than are stored is refused", {
  expect_true(library_fetch_looks_complete(719, 719))
  expect_true(library_fetch_looks_complete(725, 719))
  expect_true(library_fetch_looks_complete(500, 719))
  expect_false(library_fetch_looks_complete(300, 719))
  expect_false(library_fetch_looks_complete(0, 719))                       # the API returned nothing
  expect_false(library_fetch_looks_complete(NA, 719))
})

test_that("with nothing stored, or the stored count unknown, a non-empty fetch goes through", {
  expect_true(library_fetch_looks_complete(719, 0))
  expect_true(library_fetch_looks_complete(719, NA))
  expect_false(library_fetch_looks_complete(0, NA))
  expect_false(library_fetch_looks_complete(0, 0))
})

test_that("the limit is a share you can set", {
  expect_false(library_fetch_looks_complete(600, 719, min_share = 0.9))
  expect_true(library_fetch_looks_complete(700, 719, min_share = 0.9))
})

# ---- the atomic request carries it ----

test_that("the whole replacement fits in one atomic request, with the deletes first and the inserts after", {
  s <- library_replace_statements(make_libraries(1:719), make_services(1:719, paste("S", 1:16)))
  req <- build_atomic_batch(s)
  steps <- req$batch$steps
  expect_equal(length(steps), length(s) + 3)                              # BEGIN, the statements, COMMIT, ROLLBACK
  expect_equal(steps[[1]]$stmt$sql, "BEGIN")
  expect_equal(steps[[2]]$stmt$sql, "DELETE FROM library_services")
  expect_equal(steps[[3]]$stmt$sql, "DELETE FROM libraries")
  expect_equal(steps[[length(steps) - 1]]$stmt$sql, "COMMIT")
  # no step may have more variables than SQLite allows
  expect_true(all(vapply(steps, function(x) length(x$stmt$args), 1L) <= 32766))
})
