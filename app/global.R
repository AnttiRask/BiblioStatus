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

source("www/variables.R")
source("www/strings.R")
source("www/functions.R")
source("www/filter_logic.R")
source("www/health.R")
source("www/data_layer.R")
source("modules/service_stats.R")

# Warm the shared data cache so the first visitor doesn't wait for Turso
if (!isTRUE(getOption("bibliostatus.skip_warm"))) try(get_app_data(), silent = TRUE)
