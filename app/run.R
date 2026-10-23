library(shiny)

# Run from the app directory so ui.R / server.R find their relative paths,
# and wrap the page handler so every page response carries security headers
# and GET /health answers the uptime monitor
source("app/www/security.R")
source("app/www/health.R")
setwd("app")

port <- as.integer(Sys.getenv("PORT", "8080"))
# The health check sits inside the security wrapper, so its answer gets the headers
app <- with_security_headers(with_health_check(shinyAppDir(".")))
runApp(app, host = "0.0.0.0", port = port)
