library(here)
library(rsconnect)

source(here("app/www/secret.R"))

setAccountInfo(
    name   = SHINY_APPS_NAME,
    token  = SHINY_APPS_TOKEN,
    secret = SHINY_APPS_SECRET
)

deployApp(
    appDir      = here("app/"),
    appName     = "BiblioStatus",
    account     = "youcanbeapirate",
    forceUpdate = TRUE
)
