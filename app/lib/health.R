# Health check for the uptime monitor: GET /health (see with_health_check() below,
# wrapped in run.R). 200 and "ok" when the data is healthy, 503 and a short reason
# when it is not. A page that returns 200 on "/" is not enough: the page shell
# loads even when Turso is down (the SQLite backup hides that from visitors) or
# when the nightly update has been failing for days. The reasons carry no error
# details.
#
# Problems reported (joined with "; "):
#   unavailable   neither Turso nor the SQLite backup can be read
#   empty         there are no libraries
#   no_schedules  there are no opening hours for today (every library would show
#                 "no status data")
#   stale         the newest stored opening hours are less than
#                 health_min_days_ahead days ahead: the nightly update stores a
#                 week, so this is the early warning, days before no_schedules
#   degraded      the SQLite backup is being used because Turso fails

# What the data looks like right now: where it was read from, and how much of it.
# Turso first; the SQLite backup only if Turso fails (the same order the app uses).
# `today` is the Finnish date as "YYYY-MM-DD".
health_probe <- function(today = format(helsinki_today(), "%Y-%m-%d")) {
  from_turso <- tryCatch({
    one <- function(sql, params = list()) turso_query(sql, params)[[1]][1]
    list(
      libraries = as.integer(one("SELECT COUNT(*) AS n FROM libraries")),
      schedules_today = as.integer(one("SELECT COUNT(*) AS n FROM schedules WHERE date = ?", list(today))),
      newest_date = as.character(one("SELECT MAX(date) AS newest FROM schedules"))
    )
  }, error = function(e) NULL)
  if (!is.null(from_turso)) return(c(list(source = "turso"), from_turso))

  from_sqlite <- tryCatch({
    con <- dbConnect(SQLite(), dbname = db_path, read_only = TRUE)
    on.exit(dbDisconnect(con))
    list(
      libraries = as.integer(dbGetQuery(con, "SELECT COUNT(*) AS n FROM libraries")$n),
      schedules_today = as.integer(dbGetQuery(con, "SELECT COUNT(*) AS n FROM schedules WHERE date = ?", params = list(today))$n),
      newest_date = as.character(dbGetQuery(con, "SELECT MAX(date) AS newest FROM schedules")$newest)
    )
  }, error = function(e) NULL)
  if (!is.null(from_sqlite)) return(c(list(source = "sqlite"), from_sqlite))

  list(source = "none", libraries = 0L, schedules_today = 0L, newest_date = NA_character_)
}

# The answer for a probe: list(ok, body). Pure, so every case is tested.
health_status <- function(probe = health_probe(),
                          today = helsinki_today(),
                          min_days_ahead = health_min_days_ahead) {
  problems <- character()

  if (identical(probe$source, "none")) {
    problems <- c(problems, "unavailable: neither Turso nor the SQLite backup can be read")
  } else if (is.na(probe$libraries) || probe$libraries == 0) {
    problems <- c(problems, "empty: there are no libraries")
  } else {
    if (is.na(probe$schedules_today) || probe$schedules_today == 0) {
      problems <- c(problems, "no_schedules: there are no opening hours for today")
    } else {
      newest <- as.Date(probe$newest_date, optional = TRUE)   # NA, not an error, for a bad date
      if (is.na(newest) || newest < today + min_days_ahead) {
        problems <- c(problems, sprintf(
          "stale: the newest opening hours are for %s, the nightly update may be failing",
          if (is.na(newest)) "an unreadable date" else format(newest, "%Y-%m-%d")
        ))
      }
    }
    if (identical(probe$source, "sqlite")) {
      problems <- c(problems, "degraded: serving the SQLite backup because Turso fails")
    }
  }

  list(ok = length(problems) == 0, body = if (length(problems) == 0) "ok" else paste(problems, collapse = "; "))
}

# A monitor checks from several places every few minutes: answer from a short
# cache instead of querying Turso for each of them.
health_cache <- new.env()
cached_health <- function(check = function() health_status(), now = Sys.time(),
                          max_age_seconds = health_cache_seconds) {
  if (!is.null(health_cache$time) && as.numeric(difftime(now, health_cache$time, units = "secs")) < max_age_seconds) {
    return(health_cache$result)
  }
  result <- check()
  health_cache$time <- now
  health_cache$result <- result
  result
}

# Wrap a Shiny app object so GET and HEAD requests for `path` get the health answer
# and everything else goes to the app. Wrap the result with with_security_headers()
# so the answer carries the headers too.
with_health_check <- function(app, path = "/health", check = cached_health) {
  original <- app$httpHandler
  app$httpHandler <- function(req) {
    method <- req$REQUEST_METHOD
    if (identical(req$PATH_INFO, path) && (is.null(method) || method %in% c("GET", "HEAD"))) {
      result <- tryCatch(
        check(),
        error = function(e) {
          message("The health check failed: ", conditionMessage(e))
          list(ok = FALSE, body = "unavailable: the health check itself failed")
        }
      )
      return(shiny::httpResponse(
        status       = if (result$ok) 200L else 503L,
        content_type = "text/plain; charset=utf-8",
        content      = result$body,
        headers      = list("Cache-Control" = "no-store")
      ))
    }
    original(req)
  }
  app
}
