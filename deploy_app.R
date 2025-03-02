library(here)
library(rsconnect)

# Uncomment for the local version
# source(here("app/www/secret.R"))
# fmt: skip
# setAccountInfo(
#   name   = SHINY_APPS_NAME,
#   token  = SHINY_APPS_TOKEN,
#   secret = SHINY_APPS_SECRET
# )

# fmt: skip
setAccountInfo(
  name   = Sys.getenv("SHINY_APPS_NAME"),
  token  = Sys.getenv("SHINY_APPS_TOKEN"),
  secret = Sys.getenv("SHINY_APPS_SECRET")
)

# fmt: skip
deployApp(
  appDir      = here("app/"),
  appName     = "BiblioStatus",
  account     = Sys.getenv("SHINY_APPS_NAME"),
  forceUpdate = TRUE
)
