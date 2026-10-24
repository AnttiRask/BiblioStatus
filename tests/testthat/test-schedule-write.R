# How the nightly job replaces the stored schedules (R/schedules.R, R/turso.R).
# The first version deleted the whole window of days and then inserted the new
# rows in separate requests; for the three minutes that took, the libraries at the
# end of the list had no schedule and showed as "no status data" (2026-10-24).
# The invariant tested here: at no moment is a library without rows.

window_dates <- c("2026-10-24", "2026-10-25", "2026-10-26")

make_rows <- function(ids, hours = "09:00", dates = window_dates, periods = 1) {
  tidyr::expand_grid(library_id = ids, date = dates, period = seq_len(periods)) |>
    dplyr::mutate(
      from_time = ifelse(period == 1, hours, "18:00"),
      to_time = ifelse(period == 1, "17:00", "20:00"),
      status_label = "Open"
    ) |>
    dplyr::select(library_id, date, from_time, to_time, status_label)
}

# An in-memory database standing in for Turso
new_db <- function(env = parent.frame()) {
  con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  DBI::dbExecute(con, "CREATE TABLE schedules (library_id INTEGER, date TEXT, from_time TEXT, to_time TEXT, status_label TEXT,
                       UNIQUE (library_id, date, from_time, to_time, status_label))")
  withr::defer(DBI::dbDisconnect(con), envir = env)
  con
}
store <- function(con, rows) DBI::dbWriteTable(con, "schedules", as.data.frame(rows), append = TRUE)
run_group <- function(con, group) {
  # what the atomic batch does for Turso: all of a group's statements, or none
  DBI::dbWithTransaction(con, for (s in group) DBI::dbExecute(con, s$sql, params = unname(s$params)))
}
libraries_with_rows <- function(con, dates = window_dates) {
  r <- DBI::dbGetQuery(con, "SELECT library_id, COUNT(DISTINCT date) AS days FROM schedules WHERE date >= ? GROUP BY library_id",
                       params = list(min(dates)))
  r$library_id[r$days == length(dates)]
}

test_that("every library is in exactly one group, with its delete and all of its rows", {
  new <- make_rows(1:40, periods = 2)
  groups <- schedule_write_groups(new, first_date = "2026-10-24", max_statements = 50)

  expect_gt(length(groups), 1)
  deletes <- vapply(groups, function(g) grepl("^DELETE", g[[1]]$sql), logical(1))
  expect_true(all(deletes))                                                  # a group starts with its delete
  inserts <- unlist(lapply(groups, function(g) g[-1]), recursive = FALSE)
  expect_length(inserts, nrow(new))                                          # every row, once
  expect_true(all(vapply(inserts, function(s) grepl("^INSERT", s$sql), logical(1))))

  deleted <- unlist(lapply(groups, function(g) unlist(g[[1]]$params[-1])))
  expect_setequal(deleted, 1:40)
  expect_equal(anyDuplicated(deleted), 0)
  # a group deletes exactly the libraries whose rows it inserts
  for (g in groups) {
    ids_deleted <- unlist(g[[1]]$params[-1])
    ids_inserted <- unique(vapply(g[-1], function(s) s$params[[1]], numeric(1)))
    expect_setequal(ids_deleted, ids_inserted)
    expect_equal(g[[1]]$params[[1]], "2026-10-24")
  }
})

test_that("a group's placeholders match its parameters", {
  groups <- schedule_write_groups(make_rows(1:10), first_date = "2026-10-24", max_statements = 40)
  for (g in groups) {
    for (s in g) expect_equal(lengths(regmatches(s$sql, gregexpr("\\?", s$sql))), length(s$params))
  }
})

test_that("a group is no bigger than the limit, except a single library that is bigger itself", {
  groups <- schedule_write_groups(make_rows(1:40, periods = 2), first_date = "2026-10-24", max_statements = 50)
  expect_true(all(lengths(groups) <= 50))
  one_big <- schedule_write_groups(make_rows(1, periods = 2), first_date = "2026-10-24", max_statements = 3)
  expect_length(one_big, 1)
  expect_equal(length(one_big[[1]]), 1 + 6)
})

test_that("no library is ever without rows while the window is replaced", {
  con <- new_db()
  store(con, make_rows(1:60, hours = "08:00"))
  new <- make_rows(1:60, hours = "10:00")
  groups <- schedule_write_groups(new, first_date = "2026-10-24", max_statements = 40)
  expect_gt(length(groups), 3)

  for (group in groups) {
    run_group(con, group)
    expect_setequal(libraries_with_rows(con), 1:60)      # after every group, all of them still have the whole window
  }
  stored <- DBI::dbGetQuery(con, "SELECT DISTINCT from_time FROM schedules")$from_time
  expect_equal(stored, "10:00")                          # and in the end only the new hours
})

test_that("the old way (delete the window, then insert) does leave libraries without rows", {
  con <- new_db()
  store(con, make_rows(1:60))
  DBI::dbExecute(con, "DELETE FROM schedules WHERE date >= ?", params = list("2026-10-24"))
  new <- make_rows(1:60)
  half <- new[new$library_id <= 30, ]
  store(con, half)
  expect_length(setdiff(1:60, libraries_with_rows(con)), 30)       # the situation of the three minutes
})

test_that("a library the fetch returned nothing for keeps its old rows", {
  con <- new_db()
  store(con, make_rows(1:3, hours = "08:00"))
  for (g in schedule_write_groups(make_rows(1:2, hours = "10:00"), first_date = "2026-10-24")) run_group(con, g)
  hours <- DBI::dbGetQuery(con, "SELECT library_id, from_time FROM schedules GROUP BY library_id")
  expect_equal(hours$from_time, c("10:00", "10:00", "08:00"))
})

test_that("history before the window is kept", {
  con <- new_db()
  store(con, make_rows(1:2, dates = c("2026-10-20", "2026-10-21")))
  store(con, make_rows(1:2, hours = "08:00"))
  for (g in schedule_write_groups(make_rows(1:2, hours = "10:00"), first_date = "2026-10-24")) run_group(con, g)
  past <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM schedules WHERE date < '2026-10-24'")$n
  expect_equal(past, 4)
})

test_that("running it twice doesn't pile up rows, also rows without times", {
  con <- new_db()
  closed <- data.frame(library_id = rep(1:3, each = 2), date = rep(window_dates[1:2], 3),
                       from_time = NA_character_, to_time = NA_character_, status_label = "Closed for the whole day")
  new <- rbind(closed, make_rows(4:5))
  groups <- schedule_write_groups(new, first_date = "2026-10-24")
  for (i in 1:2) for (g in groups) run_group(con, g)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM schedules")$n, nrow(new))
})

test_that("a group that fails leaves nothing of it behind", {
  con <- new_db()
  store(con, make_rows(1:2, hours = "08:00"))
  bad <- schedule_write_groups(make_rows(1:2, hours = "10:00"), first_date = "2026-10-24")[[1]]
  bad[[3]]$sql <- "INSERT INTO no_such_table VALUES (?)"        # the second statement fails
  expect_error(run_group(con, bad))
  expect_equal(unique(DBI::dbGetQuery(con, "SELECT from_time FROM schedules")$from_time), "08:00")
})

# ---- the request sent to Turso ----

test_that("the atomic batch is BEGIN, the statements each after the one before, COMMIT, and a ROLLBACK if COMMIT didn't happen", {
  statements <- list(
    list(sql = "DELETE FROM schedules WHERE date >= ?", params = list("2026-10-24")),
    list(sql = "INSERT INTO schedules VALUES (?, ?)", params = list(1, NA))
  )
  req <- build_atomic_batch(statements)
  steps <- req$batch$steps
  expect_equal(req$type, "batch")
  expect_length(steps, 5)
  expect_equal(vapply(steps, function(s) s$stmt$sql, ""), c("BEGIN", statements[[1]]$sql, statements[[2]]$sql, "COMMIT", "ROLLBACK"))
  expect_null(steps[[1]]$condition)
  expect_equal(steps[[2]]$condition, list(type = "ok", step = 0))      # after BEGIN
  expect_equal(steps[[3]]$condition, list(type = "ok", step = 1))      # after the first statement
  expect_equal(steps[[4]]$condition, list(type = "ok", step = 2))      # COMMIT after the last statement
  expect_equal(steps[[5]]$condition, list(type = "not", cond = list(type = "ok", step = 3)))   # ROLLBACK unless COMMIT worked
  expect_equal(steps[[3]]$stmt$args[[2]], list(type = "null"))         # an NA is a NULL
})

test_that("a batch that committed is a success, anything else a failure with the reason", {
  ok <- list(step_results = list(list(), list(affected_row_count = 3), list(), NULL),
             step_errors = list(NULL, NULL, NULL, NULL))
  expect_null(atomic_batch_failure(ok, 1))

  failed <- list(step_results = list(list(), NULL, NULL, list()),
                 step_errors = list(NULL, list(message = "no such table: schedules"), NULL, NULL))
  expect_equal(atomic_batch_failure(failed, 1), "no such table: schedules")

  rolled_back <- list(step_results = list(list(), list(), NULL, list()), step_errors = list(NULL, NULL, NULL, NULL))
  expect_match(atomic_batch_failure(rolled_back, 1), "rolled back")
})

test_that("turso_execute_atomic sends one request and stops with the reason when it rolls back", {
  withr::local_envvar(TURSO_DATABASE_URL = "libsql://example.turso.io", TURSO_AUTH_TOKEN = "t")
  seen <- list()
  respond <- function(result) function(req) {
    seen[[length(seen) + 1]] <<- req
    # explicit nulls, as Turso sends them for steps that did not run or did not fail
    body <- jsonlite::toJSON(
      list(results = list(list(type = "ok", response = list(type = "batch", result = result)))),
      auto_unbox = TRUE, null = "null"
    )
    httr2::response(status_code = 200, headers = list(`Content-Type` = "application/json"), body = charToRaw(as.character(body)))
  }
  statements <- list(list(sql = "DELETE FROM schedules", params = list()), list(sql = "INSERT INTO schedules VALUES (1)", params = list()))

  done <- httr2::with_mocked_responses(
    respond(list(step_results = list(list(), list(affected_row_count = 4), list(affected_row_count = 1), list(), NULL),
                 step_errors = list(NULL, NULL, NULL, NULL, NULL))),
    turso_execute_atomic(statements)
  )
  expect_equal(done, 5)
  expect_length(seen, 1)                                              # one request for the group

  expect_error(
    httr2::with_mocked_responses(
      respond(list(step_results = list(list(), list(), NULL, NULL, list()),
                   step_errors = list(NULL, NULL, list(message = "disk full"), NULL, NULL))),
      turso_execute_atomic(statements)
    ),
    "rolled back: disk full"
  )
})
