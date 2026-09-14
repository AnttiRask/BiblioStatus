library(testthat)
library(here)
library(dplyr)

# app/www/functions.R and app/server.R use paths relative to the app/
# directory (source("modules/service_stats.R"), etc.), matching how the real
# Shiny app runs (Shiny sets the working directory to app/). Match that here
# so the same files can be sourced unmodified for testing.
project_root <- here()
setwd(file.path(project_root, "app"))
on.exit(setwd(project_root), add = TRUE)

source("www/functions.R")
source("www/variables.R")
source("server.R")

test_dir(file.path(project_root, "tests", "testthat"))
