# All user-facing text of the app (ui.R, server.R, the map popups, the service
# statistics module and the messages app.js shows) in one place, so a
# translation (Finnish, Swedish) only has to replace this list. Data values that
# the code compares against (status labels such as "Open") are not text and
# stay in the code. The text is used as it is in HTML, so it must not contain
# markup of its own (the code escapes it).
txt <- list(
  app_title            = "BiblioStatus",
  heading              = "Which Finnish Libraries Are Open Right Now?",
  loading              = "Loading data, please wait...",
  tab_map              = "Library Map",
  tab_stats            = "Service Statistics",

  city_label           = "Select City/Municipality:",
  finder_label         = "Search All Libraries:",
  finder_placeholder   = "Type a library name...",
  library_label        = "Select Library:",
  library_placeholder  = "All Libraries",
  service_label        = "Select Service:",
  all_cities           = "All Cities",
  all_libraries        = "All Libraries",
  all_services         = "All Services",
  clear_library        = "Clear library selection",
  clear_service        = "Clear service selection",
  reset_filters        = "Reset filters",
  mode_to_light        = "Switch to light mode",
  mode_to_dark         = "Switch to dark mode",
  summary_one          = "%d library",
  summary_many         = "%d libraries",
  find_nearest         = "Find Nearest Open Library",
  getting_location     = " Getting your location...",

  nearest_heading      = "Nearest Open Libraries:",
  nearest_heading_service = "Nearest open libraries offering %s:",
  no_open_nearby       = "No open libraries found nearby",
  no_open_nearby_service = "No open libraries offering %s found nearby",
  get_directions       = " Get Directions",
  current_status       = "Current Status:",
  todays_schedule      = "Today's Schedule:",
  no_schedule          = "No schedule information available",
  schedule_now         = " \u2190 now",
  services_heading     = "Services (in Finnish):",
  no_services          = "No services listed",

  notice_library_not_in_city = "Library cleared: it is not in %s",
  notice_library_no_service  = "Library cleared: it does not offer %s",
  notice_library_all_cities  = "Library cleared: all cities are shown",
  notice_service_not_in_city = "Service cleared: it is not offered in %s",
  notice_service_not_at_library = "Service cleared: %s does not offer %s",
  url_ignored                = "Part of the link's filters didn't match any libraries and was left out.",

  popup_status         = "Status:",
  popup_hours          = "Hours:",
  popup_hours_none     = "NA",
  popup_distance       = "Distance:",
  popup_directions     = "Get Directions",
  your_location        = "Your Location",

  geolocation_unsupported = "Geolocation is not supported by your browser",
  geolocation_denied      = "Please enable location permissions to find nearby libraries",
  geolocation_failed      = "Unable to get your location. Please try again.",

  footer_created_by    = "Created by",

  stats_heading        = "Library Service Statistics",
  stats_intro          = "Explore which services are offered by Finnish libraries across different cities",
  stats_city_label     = "Filter by City:",
  stats_top_heading    = "Top 15 Most Common Services",
  stats_all_heading    = "All Services",
  stats_title_city     = "Most Common Services in %s",
  stats_title_all      = "Most Common Library Services (All Cities)",
  stats_col_service    = "Service Name",
  stats_col_count      = "Libraries Offering",

  legend_title         = "Status",
  legend_open          = "Open",
  legend_self          = "Self-service",
  legend_closed        = "Closed",
  legend_closed_day    = "Closed for the whole day",
  legend_unknown       = "No status data",
  data_backup_notice   = "Live data is unavailable, so this is the nightly backup. Opening hours may be out of date.",
  data_stale_notice    = "Live data is temporarily unavailable. Showing the data from %s.",
  data_failed_notice   = "The library data could not be loaded. Please try again in a few minutes.",
  data_partial_notice  = "Some of the data could not be loaded, so the opening hours or services may be missing.",
  no_schedules_notice  = "Opening hours for today are not available yet, so the libraries are shown without a status. They are updated every morning."
)
