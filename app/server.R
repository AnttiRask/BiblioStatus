# Server logic. Packages, helpers and settings come from global.R.

# The rest of the server logic lives in server/*.R. The parts are parsed once,
# when this file is loaded (the working directory is app/ then), and evaluated
# inside every session's server() call so they share its input, output,
# session and reactive state. The order is the order the observers are created.
server_parts <- lapply(
  c("data", "filters", "url", "map", "panels"),
  function(part) parse(file.path("server", paste0(part, ".R")), keep.source = FALSE)
)

server <- function(input, output, session) {
  # bslib::input_dark_mode() reports the string "dark" or "light", so testing it
  # with isTRUE() was never TRUE and the map (tiles and marker colours) never
  # went dark. Accept the string, and a logical for older bslib.
  is_dark <- reactive(identical(input$dark_mode, "dark") || isTRUE(input$dark_mode))

  # Reconnect quietly if the websocket drops, e.g. when Cloud Run closes it at
  # the 3600 s timeout. TRUE would do nothing here: the client only reconnects
  # if the host (Shiny Server, Posit Connect) allows it too; "force" makes it
  # reconnect anyway. The server can't resume the old session, so a new one
  # starts and the browser re-sends its inputs (the filters, the selection,
  # the clicks), and the observers below rebuild the state from them. Keep
  # them idempotent: no paid API call or write behind an input.
  session$allowReconnect("force")

  # State: reactive containers
  library_data <- reactiveVal(NULL)
  selected_library <- reactiveVal(NULL)
  user_location <- reactiveVal(NULL)
  nearest_libraries <- reactiveVal(NULL)
  all_library_schedules <- reactiveVal(NULL)
  library_services_data <- reactiveVal(NULL)
  startup_city_set  <- reactiveVal(FALSE)    # Tracks whether initial city has been set
  startup_city      <- reactiveVal("Helsinki") # City determined on startup (geolocation / fallback)
  # What the three dropdowns hold: list(city, service, library), "" = all. The
  # rules for changing it are in www/filter_logic.R; server/filters.R connects
  # them to the inputs. The map follows it directly. Everything that needs the
  # current selection reads this and not input$*, which can lag behind what the
  # server has just sent.
  selection <- reactiveVal(empty_selection())
  # After a reconnect (see allowReconnect above) the browser re-sends the
  # dropdown values as this new session's first values. The dropdown observers
  # skip first values (ignoreInit), so the selection would start empty while the
  # dropdowns still show the old one, and the map would show the whole country.
  # Seed it from the dropdowns once, ahead of every other observer (priority).
  # On a normal page load the first values are empty and this changes nothing.
  observeEvent(
    list(input$city_filter, input$service_filter, input$library_search),
    {
      selection(normalize_selection(list(
        city = input$city_filter,
        service = input$service_filter,
        library = input$library_search
      )))
    },
    once = TRUE,
    priority = 10
  )

  # The rest of the server logic (see server_parts above)
  session_env <- environment()
  for (part in server_parts) eval(part, envir = session_env)

  # Service Statistics module (is_dark_mode is set via JS MutationObserver)
  service_stats_server("stats", library_services_data, library_data,
                       reactive(input$is_dark_mode))
}
