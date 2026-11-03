# Loaded once by Shiny before ui.R and server.R (and by tests/testthat.R, which
# runs from this directory the way Shiny does). Everything the app needs
# globally lives here: packages, config, helpers, modules.

library(bslib)
library(DT)
library(dplyr)
library(ggplot2)
library(here)
library(leaflet)
library(purrr)
library(RSQLite)
library(shiny)
library(shinyjs)

source("lib/variables.R")
source("lib/strings.R")

# What app.js gets as window.BIBLIO_CONFIG: the timings (variables.R), and the
# messages it shows itself (strings.R)
client_config <- c(geo_config, session_config, list(messages = list(
  geolocationUnsupported = txt$geolocation_unsupported,
  geolocationDenied      = txt$geolocation_denied,
  geolocationFailed      = txt$geolocation_failed,
  sessionEndedTitle      = txt$session_ended_title,
  sessionEndedText       = txt$session_ended_text,
  sessionEndedReload     = txt$session_ended_reload
)))

source("lib/functions.R")
source("lib/filter_logic.R")
source("lib/health.R")
source("lib/data_layer.R")
source("modules/service_stats.R")

# Warm the shared data cache so the first visitor doesn't wait for Turso
if (!isTRUE(getOption("bibliostatus.skip_warm"))) try(get_app_data(), silent = TRUE)
