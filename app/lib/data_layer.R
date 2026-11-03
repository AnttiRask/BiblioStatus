# The data layer: what the app shows comes from get_app_data(), which never
# throws. The libraries, the schedule rows of today and tomorrow and the
# services are read from Turso (SQLite backup if that fails), shared by every
# session for data_cache_seconds, and described by a state the page can show.
#
# get_app_data() returns
#   libraries, schedules, services  data frames (NULL libraries: nothing to show)
#   source      "turso", "sqlite" (the backup), or "none" (nothing could be read)
#   fetched_at  when the data was read (POSIXct)
#   stale       TRUE when this is older Turso data shown while Turso is down
#   error       NULL, or why part of the data (or all of it) is missing
# The fetch_*() functions are looked up when called, so tests can replace them.

empty_schedules <- function() {
  data.frame(
    library_id = integer(), date = character(), from = character(),
    to = character(), status_label = character(), stringsAsFactors = FALSE
  )
}

# Run one fetch; the result is the data (without its "source" tag), where it
# came from, and the error if it failed. Never throws.
fetch_part <- function(fetch) {
  tryCatch({
    result <- fetch()
    source <- attr(result, "source", exact = TRUE) %||% "turso"
    attr(result, "source") <- NULL
    list(data = result, source = source, error = NULL)
  }, error = function(e) {
    list(data = NULL, source = "none", error = conditionMessage(e))
  })
}

# Read everything once, without the cache. Libraries are the one thing the page
# can't do without; missing schedules or services only degrade it.
load_app_data <- function(now = Sys.time()) {
  libraries <- fetch_part(function() fetch_libraries())
  schedules <- fetch_part(function() fetch_schedules())
  services  <- fetch_part(function() fetch_library_services())
  parts <- list(libraries = libraries, schedules = schedules, services = services)

  errors <- unlist(lapply(parts, function(p) p$error))
  no_libraries <- is.null(libraries$data) || nrow(libraries$data) == 0
  if (no_libraries && is.null(libraries$error)) errors <- c(libraries = "no libraries", errors)

  sources <- vapply(parts, function(p) p$source, character(1))
  source <- if (no_libraries) "none" else if (any(sources == "sqlite")) "sqlite" else "turso"

  list(
    libraries = if (no_libraries) NULL else libraries$data,
    schedules = schedules$data %||% empty_schedules(),
    services  = services$data %||% data.frame(library_id = integer(), service_name = character()),
    source = source,
    fetched_at = now,
    stale = FALSE,
    error = if (length(errors)) paste(names(errors), errors, sep = ": ", collapse = "; ") else NULL
  )
}

# The shared cache. `served` is what visitors get until it expires; `good` is
# the last complete read from Turso, kept to show (marked stale) when a later
# read has to fall back to the backup or fails.
data_cache <- new.env()

data_cache_clear <- function() {
  rm(list = ls(data_cache, all.names = TRUE), envir = data_cache)
}

# Seconds to share the data; options(bibliostatus.data_cache_seconds = 0) turns
# the cache off (the tests do, since they replace the fetch functions)
data_cache_ttl <- function() getOption("bibliostatus.data_cache_seconds", data_cache_seconds)

seconds_since <- function(then, now) as.numeric(difftime(now, then, units = "secs"))

get_app_data <- function(now = Sys.time(), dates = schedule_dates_to_load()) {
  if (data_cache_ttl() <= 0) return(load_app_data(now))

  cache <- data_cache
  if (!is.null(cache$served) && identical(cache$dates, dates) &&
      seconds_since(cache$served_at, now) < cache$ttl) {
    return(cache$served)
  }

  fresh <- load_app_data(now)
  if (fresh$source == "turso" && is.null(fresh$error)) {
    cache$good <- fresh
    cache$good_dates <- dates
    value <- fresh
    ttl <- data_cache_ttl()
  } else {
    good <- cache$good
    usable <- !is.null(good) && identical(cache$good_dates, dates) &&
      seconds_since(good$fetched_at, now) < data_max_stale_seconds
    value <- if (usable) {
      modifyList(good, list(stale = TRUE, error = fresh$error %||% "Turso unavailable"))
    } else {
      fresh
    }
    ttl <- data_retry_seconds
  }

  cache$served <- value
  cache$served_at <- now
  cache$dates <- dates
  cache$ttl <- ttl
  value
}

# What the page says about the data, or NULL when there is nothing to say.
# `state` is get_app_data() without the data frames; the backup and stale
# notices replace the "no opening hours yet" one, which would blame the
# nightly update for what is really a Turso problem.
data_notice_for <- function(state, schedules_empty) {
  if (is.null(state)) return(NULL)
  if (state$source == "none") return(list(text = txt$data_failed_notice, class = "alert-danger"))
  if (isTRUE(state$stale)) {
    at <- format(state$fetched_at, tz = "Europe/Helsinki", "%H:%M")
    return(list(text = sprintf(txt$data_stale_notice, at), class = "alert-info"))
  }
  if (state$source == "sqlite") return(list(text = txt$data_backup_notice, class = "alert-info"))
  if (!is.null(state$error)) return(list(text = txt$data_partial_notice, class = "alert-warning"))
  if (isTRUE(schedules_empty)) return(list(text = txt$no_schedules_notice, class = "alert-warning"))
  NULL
}
