# Light mode colors
# fmt: skip
light_colors <- list(
    Open       = "#0072B2",
    Self       = "#E69F00",
    ClosedNow  = "#D55E00",
    ClosedDay  = "#999999",
    Unknown    = "#800080"
)

# Dark mode colors
# fmt: skip
dark_colors <- list(
    Open       = "#00C0FF",
    Self       = "#FFD700",
    ClosedNow  = "#FF4444",
    ClosedDay  = "#FFFFFF",
    Unknown    = "#DA70D6"
)

# Basemap: Esri's World Light / Dark Gray canvas (no API key needed). Each theme
# is a base layer plus a labels ("Reference") layer drawn on top. The tiles are
# real only up to zoom 16; from 17 on Esri serves a grey "Map data not yet
# available" tile, so tile requests are capped at 16 and scaled up beyond that.
map_tiles_host <- "https://services.arcgisonline.com"
map_tile_max_native_zoom <- 16
map_max_zoom <- 18
map_attribution <- paste0(
  "Tiles &copy; Esri &mdash; Esri, HERE, Garmin, &copy; ",
  '<a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> ',
  "contributors, and the GIS user community"
)

# Marker sizing, zoom, and result-count tuning (mobile gets larger touch targets)
MOBILE_MARKER_RADIUS <- 10
DESKTOP_MARKER_RADIUS <- 8
MOBILE_NEAREST_MARKER_RADIUS <- 12
DESKTOP_NEAREST_MARKER_RADIUS <- 10
USER_LOCATION_MARKER_RADIUS <- 10
MOBILE_POPUP_MAX_WIDTH <- 250
MOBILE_POPUP_MIN_WIDTH <- 200
DESKTOP_POPUP_MAX_WIDTH <- 300
DESKTOP_POPUP_MIN_WIDTH <- 100
DEFAULT_ZOOM_LEVEL <- 11
SINGLE_LIBRARY_ZOOM_THRESHOLD <- 2
MOBILE_NEAREST_COUNT <- 3
DESKTOP_NEAREST_COUNT <- 5

# Cross-links in the footer of every youcanbeapirate app; the current app
# leaves itself out
footer_apps <- list(
  list(id = "bibliostatus", name = "BiblioStatus",       url = "https://bibliostatus.youcanbeapirate.com"),
  list(id = "fillaristatus", name = "FillariStatus",     url = "https://fillaristatus.youcanbeapirate.com"),
  list(id = "gallery",      name = "Gallery of the Day", url = "https://galleryoftheday.youcanbeapirate.com"),
  list(id = "trackteller",  name = "TrackTeller",        url = "https://trackteller.youcanbeapirate.com"),
  list(id = "tuneteller",   name = "TuneTeller",         url = "https://tuneteller.youcanbeapirate.com")
)

# Geolocation timing for app.js (ms). Startup uses a coarse/cached location for a
# fast first paint; Find Nearest waits longer for a precise, fresh fix.
geo_config <- list(
  startupTimeoutMs     = 8000,
  startupMaxAgeMs      = 600000,
  startupFallbackMs    = 9000,   # give up on the startup location and use Helsinki
  findNearestTimeoutMs = 10000,
  findNearestMaxAgeMs  = 300000
)

# Brand colours. The red is for the light page; on the dark page it is too dim
# (3.1:1 on the dark background), so text uses the lighter red there.
brand_colours <- list(
  red         = "#C1272D",
  red_on_dark = "#F26B70",
  dark_bg     = "#191414"
)

