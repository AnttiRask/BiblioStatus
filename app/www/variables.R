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
