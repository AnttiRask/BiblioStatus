# Opening-hours schedules from the Kirkanta API: the dates the pipeline keeps and
# the parsing of the API response. No Turso or file access here, so the parser can
# be tested against saved responses (tests/testthat/test-schedules.R).
#
# The pipeline stores a window of days (today and the following days) instead of
# only today. GitHub starts scheduled workflows hours late, so a run that only
# stored its own day left the app without any status for the first hours of the
# day (every library showed as unknown). With the window, yesterday's run has
# already stored today.

schedule_window_days <- 7

# Today's date in Finland, where the libraries are. Sys.Date() is the date in the
# server's time zone (UTC on Cloud Run and GitHub), which is yesterday for the
# first hours of the Finnish day.
helsinki_today <- function(now = Sys.time()) {
  as.Date(format(now, tz = "Europe/Helsinki", "%Y-%m-%d"))
}

# The dates (as "YYYY-MM-DD" text) the pipeline fetches and stores
schedule_window <- function(today = helsinki_today(), days = schedule_window_days) {
  as.character(seq(today, by = "day", length.out = days))
}

unknown_schedule_rows <- function(library_id, dates) {
  tibble::tibble(
    library_id   = rep(library_id, length(dates)),
    date         = as.character(dates),
    from_time    = rep(NA_character_, length(dates)),
    to_time      = rep(NA_character_, length(dates)),
    status_label = rep("Unknown", length(dates))
  )
}

# The API's status numbers
schedule_status_label <- function(status) {
  dplyr::case_when(
    status == 0 ~ "Temporarily closed",
    status == 1 ~ "Open",
    status == 2 ~ "Self-service",
    TRUE ~ "Unknown"
  )
}

# `items` is the parsed `items` of a /v4/schedules response (one row per date,
# with a closed flag and a list-column `times`), or NULL when the request failed.
# Returns one row per opening period (library_id, date, from_time, to_time,
# status_label); a closed day is one row "Closed for the whole day", and a date
# the API gave nothing usable for is one "Unknown" row, so every library has a
# row for every date in `dates`.
parse_schedule_items <- function(items, library_id, dates) {
  rows <- list()

  if (!is.null(items) && length(items) > 0 && nrow(items) > 0 && "date" %in% names(items)) {
    for (i in seq_len(nrow(items))) {
      day <- as.character(items$date[[i]])
      if (!day %in% dates) next

      closed <- if ("closed" %in% names(items)) isTRUE(items$closed[[i]]) else FALSE
      times <- if ("times" %in% names(items)) items$times[[i]] else NULL

      rows[[length(rows) + 1]] <- if (closed) {
        tibble::tibble(
          library_id = library_id, date = day,
          from_time = NA_character_, to_time = NA_character_,
          status_label = "Closed for the whole day"
        )
      } else if (is.null(times) || !all(c("from", "to") %in% names(times)) || nrow(times) == 0) {
        unknown_schedule_rows(library_id, day)
      } else {
        tibble::tibble(
          library_id = library_id, date = day,
          from_time = as.character(times$from), to_time = as.character(times$to),
          status_label = schedule_status_label(times$status)
        )
      }
    }
  }

  found <- dplyr::bind_rows(rows)
  present <- if (nrow(found) > 0) found$date else character()
  missing <- setdiff(dates, present)
  dplyr::bind_rows(found, unknown_schedule_rows(library_id, missing)) |>
    dplyr::arrange(date, from_time)
}

# Same, from the text of a response
parse_schedule_response <- function(json_text, library_id, dates) {
  items <- jsonlite::fromJSON(json_text, flatten = TRUE)$items
  parse_schedule_items(items, library_id, dates)
}

# One request per library for the whole window. A failed request gives
# "Unknown" rows for the library instead of stopping the run.
fetch_schedules_from_api <- function(libraries, dates = schedule_window()) {
  api_url <- "https://api.kirjastot.fi/v4/schedules"

  purrr::map_dfr(libraries$id, function(library_id) {
    response <- tryCatch(
      httr::RETRY(
        "GET", api_url,
        query = list(library = library_id, period.start = min(dates), period.end = max(dates)),
        times = 3, pause_base = 1, quiet = TRUE
      ),
      error = function(e) NULL
    )

    if (is.null(response) || httr::status_code(response) != 200) {
      return(unknown_schedule_rows(library_id, dates))
    }
    parse_schedule_response(httr::content(response, "text", encoding = "UTF-8"), library_id, dates)
  })
}

# The statements that replace the stored schedules of the window with freshly
# fetched ones, planned so that no library is ever without rows: the libraries
# are split into groups, and each group (a list of statements) is meant to run as
# ONE transaction (turso_execute_atomic()): delete the group's rows from
# `first_date` on, insert its new rows. A reader sees either a group's old rows or
# its new ones. (The first version deleted the whole window and then inserted in
# separate requests: for the three minutes that took, the libraries at the end of
# the list had no schedule and showed as "no status data".) A library the fetch
# returned nothing for is left alone: its old rows stay.
# `schedules` has library_id, date, from_time, to_time, status_label.
schedule_write_groups <- function(schedules, first_date, max_statements = 200) {
  insert_sql <- "INSERT OR IGNORE INTO schedules (library_id, date, from_time, to_time, status_label)
               VALUES (?, ?, ?, ?, ?)"
  by_library <- split(schedules, factor(schedules$library_id, levels = unique(schedules$library_id)))

  groups <- list()
  current <- list()
  ids <- character()
  close_group <- function() {
    if (length(ids) == 0) return(invisible())
    delete <- list(
      sql = sprintf(
        "DELETE FROM schedules WHERE date >= ? AND library_id IN (%s)",
        paste(rep("?", length(ids)), collapse = ", ")
      ),
      params = c(list(first_date), as.list(ids))
    )
    groups[[length(groups) + 1]] <<- c(list(delete), current)
    current <<- list()
    ids <<- character()
  }

  for (rows in by_library) {
    inserts <- lapply(seq_len(nrow(rows)), function(i) {
      list(sql = insert_sql, params = list(rows$library_id[i], rows$date[i], rows$from_time[i],
                                           rows$to_time[i], rows$status_label[i]))
    })
    if (length(ids) > 0 && length(current) + length(inserts) + 1 > max_statements) close_group()
    current <- c(current, inserts)
    ids <- c(ids, as.character(rows$library_id[1]))
  }
  close_group()
  groups
}

