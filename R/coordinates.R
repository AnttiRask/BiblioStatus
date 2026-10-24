# Where the libraries are. The coordinates come from the Kirkanta API, which once
# had 0, 0 (off the coast of Africa) for a library. This file decides which
# coordinates to believe, with no file or network access of its own (the pipeline
# passes the data in), so it can be tested on its own (test-coordinates.R).
#
# For each library, in this order:
#   1. data/library_coordinate_overrides.csv  (set by hand, always wins)
#   2. the API's coordinates, if they can be in Finland
#   3. data/library_coordinates.csv, the last good coordinates of every library
#      (a snapshot the weekly job keeps up to date from 1 and 2)
#   4. nothing: the library is left out of the data, with a warning

# A bit more than Finland (Åland to Utsjoki, Vaalimaa to Käsivarsi): a library
# outside it has wrong coordinates and must not decide where the map looks
finland_bounds <- list(lat = c(59.5, 70.5), lon = c(19, 32))

# TRUE for coordinates that can be in Finland. Vector-safe; NA is not plausible.
plausible_location <- function(lat, lon) {
  !is.na(lat) & !is.na(lon) &
    lat >= finland_bounds$lat[1] & lat <= finland_bounds$lat[2] &
    lon >= finland_bounds$lon[1] & lon <= finland_bounds$lon[2]
}

# The libraries' coordinates (see the order above).
#   libraries  id, lat, lon as the API gave them (NA allowed)
#   overrides  id, lat, lon
#   snapshot   id, lat, lon
# Returns id, lat, lon and `source` ("override", "api", "snapshot" or "none";
# lat and lon are NA for "none"), in the order of `libraries`.
resolve_coordinates <- function(libraries, overrides, snapshot) {
  at <- function(table, ids, column) table[[column]][match(ids, table$id)]
  ids <- libraries$id

  override_lat <- at(overrides, ids, "lat")
  override_lon <- at(overrides, ids, "lon")
  has_override <- !is.na(override_lat) & !is.na(override_lon)

  api_ok <- plausible_location(libraries$lat, libraries$lon)

  snapshot_lat <- at(snapshot, ids, "lat")
  snapshot_lon <- at(snapshot, ids, "lon")
  snapshot_ok <- plausible_location(snapshot_lat, snapshot_lon)

  source <- ifelse(has_override, "override",
            ifelse(api_ok, "api",
            ifelse(snapshot_ok, "snapshot", "none")))

  data.frame(
    id = ids,
    lat = ifelse(source == "override", override_lat,
          ifelse(source == "api", libraries$lat,
          ifelse(source == "snapshot", snapshot_lat, NA_real_))),
    lon = ifelse(source == "override", override_lon,
          ifelse(source == "api", libraries$lon,
          ifelse(source == "snapshot", snapshot_lon, NA_real_))),
    source = source,
    stringsAsFactors = FALSE
  )
}

# The snapshot table for a set of resolved coordinates: id, lat, lon and the
# library's name (for people reading the file), in id order, six decimals (about
# 10 cm) so that rounding noise doesn't make the file change every week.
# `libraries` has id and library_branch_name.
build_coordinate_snapshot <- function(resolved, libraries) {
  kept <- resolved[resolved$source != "none", ]
  out <- data.frame(
    id = kept$id,
    lat = round(kept$lat, 6),
    lon = round(kept$lon, 6),
    name = libraries$library_branch_name[match(kept$id, libraries$id)],
    stringsAsFactors = FALSE
  )
  out <- out[order(out$id), ]
  rownames(out) <- NULL
  out
}

read_coordinate_snapshot <- function(path) {
  if (!file.exists(path)) {
    return(data.frame(id = numeric(), lat = numeric(), lon = numeric(), name = character(), stringsAsFactors = FALSE))
  }
  utils::read.csv(path, stringsAsFactors = FALSE, encoding = "UTF-8")
}

# Write the snapshot unless the file already says the same (so a week without
# news is not a commit). TRUE if the file was written.
write_coordinate_snapshot <- function(snapshot, path) {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp))
  utils::write.csv(snapshot, tmp, row.names = FALSE, fileEncoding = "UTF-8")
  if (file.exists(path) && identical(readLines(tmp, encoding = "UTF-8"), readLines(path, encoding = "UTF-8"))) {
    return(FALSE)
  }
  file.copy(tmp, path, overwrite = TRUE)
  TRUE
}
