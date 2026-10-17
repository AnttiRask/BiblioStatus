library(shiny)

# Run from the app directory so ui.R / server.R find their relative paths,
# and wrap the page handler so every page response carries security headers
source("app/www/security.R")
setwd("app")

port <- as.integer(Sys.getenv("PORT", "8080"))
app <- with_security_headers(shinyAppDir("."))
runApp(app, host = "0.0.0.0", port = port)
