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

# No warm-up read of the data when global.R loads, and no shared data cache:
# the tests replace the fetch functions and must see their own data each time
options(bibliostatus.skip_warm = TRUE, bibliostatus.data_cache_seconds = 0)

source("global.R")
source("server.R")

# stop_on_failure makes Rscript exit non-zero, so CI goes red on a failing test
test_dir(file.path(project_root, "tests", "testthat"), stop_on_failure = TRUE)
