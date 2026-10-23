# All user-facing text of the main app (ui.R and server.R) in one place, so a
# translation (Finnish, Swedish) only has to replace this list. Data values that
# the code compares against (status labels such as "Open") are not text and
# stay in the code. Text inside the popup helper (functions.R) and the
# service statistics module is not moved yet.
txt <- list(
  app_title            = "BiblioStatus",
  heading              = "Which Finnish Libraries Are Open Right Now?",
  loading              = "Loading data, please wait...",
  tab_map              = "Library Map",
  tab_stats            = "Service Statistics",

  city_label           = "Select City/Municipality:",
  library_label        = "Select Library:",
  library_placeholder  = "All Libraries",
  service_label        = "Select Service:",
  all_cities           = "All Cities",
  all_libraries        = "All Libraries",
  all_services         = "All Services",
  clear_library        = "Clear library selection",
  clear_service        = "Clear service selection",
  reset_filters        = "Reset filters",
  summary_one          = "%d library",
  summary_many         = "%d libraries",
  find_nearest         = "Find Nearest Open Library",
  getting_location     = " Getting your location...",

  nearest_heading      = "Nearest Open Libraries:",
  no_open_nearby       = "No open libraries found nearby",
  get_directions       = " Get Directions",
  current_status       = "Current Status:",
  todays_schedule      = "Today's Schedule:",
  no_schedule          = "<p>No schedule information available</p>",
  services_heading     = "Services (in Finnish):",
  no_services          = "No services listed",

  notice_library_not_in_city = "Library cleared: it is not in %s",
  notice_library_no_service  = "Library cleared: it does not offer %s",
  notice_service_not_in_city = "Service cleared: it is not offered in %s",

  legend_title         = "Status",
  legend_open          = "Open",
  legend_self          = "Self-service",
  legend_closed        = "Closed",
  legend_closed_day    = "Closed for the whole day"
)
