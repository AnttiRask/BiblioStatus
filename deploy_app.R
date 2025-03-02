library(here)
library(rsconnect)

# source(here("app/www/secret.R")) need this only for the local version

# fmt: skip
setAccountInfo(
  name   = SHINY_APPS_NAME,
  token  = SHINY_APPS_TOKEN,
  secret = SHINY_APPS_SECRET
)

# fmt: skip
deployApp(
  appDir      = here("app/"),
  appName     = "BiblioStatus",
  account     = "youcanbeapirate",
  forceUpdate = TRUE
)
