# 📚 BiblioStatus

**BiblioStatus** is a Shiny web app that shows the real-time opening status of Finnish public libraries on a map interface. Users can explore open/self-service/closed statuses for library branches across the country.

## 🔍 Features

- 🌍 Interactive leaflet map with open/closed statuses color-coded
- 📱 Mobile-optimized layout with adjusted UI
- 🌗 Dark mode toggle
- 🏢 City/municipality filter
- 🔗 Clickable popups with library information and links
- 📦 Data updated daily via GitHub Actions and stored in SQLite

## 📸 Screenshot

![](screenshot.png)

## 🚀 Live App

👉 [Try it live on shinyapps.io](https://youcanbeapirate.shinyapps.io/BiblioStatus/)

## 🛠️ Project Structure

```
app/
├── libraries.sqlite        # SQLite file to store the data pulled from the API 
├── fetch_library_data.R    # Pulls data from [Kirkanta API (v4)](https://api.kirjastot.fi/)
├── deploy_app.R            # Deploy script using rsconnect
├── rsconnect/              # Connecting to the shinyappss.io for deployment
├── run.R                   # Running the app
├── server.R                # Server logic and reactivity
├── ui.R                    # UI definition
└── www/
    ├── functions.R         # SQLite read helpers
    ├── styles.css          # Custom styles
    └── variables.R         # Color config
```

## 🔄 Data Pipeline

1. **GitHub Actions** runs `fetch_library_data.R` nightly.
2. It fetches library info + schedules from [Kirkanta API (v4)](https://api.kirjastot.fi/).
3. Saves to `libraries.sqlite` in `app/`.
4. App loads the database on startup.

## 🔐 Deployment

This project uses rsconnect to deploy to shinyapps.io:

```r
source("deploy_app.R")
```

Secrets are passed through environment variables:
SHINY_APPS_NAME, SHINY_APPS_TOKEN, SHINY_APPS_SECRET

## 🧪 Local Development

```r
# Install dependencies
renv::restore()

# Fetch fresh data
source("fetch_library_data.R")

# Run app locally
shiny::runApp("app/")
```

You may need to modify database paths in functions.R if testing locally.

## 📦 Required R Packages

- [dplyr](https://dplyr.tidyverse.org/)
- [here](https://here.r-lib.org/)
- [jsonlite](https://github.com/jeroen/jsonlite)
- [leaflet](https://rstudio.github.io/leaflet/)
- [purrr](https://purrr.tidyverse.org/)
- [rsconnect](https://rstudio.github.io/rsconnect/)
- [RSQLite](https://rsqlite.r-dbi.org/)
- [shiny](https://shiny.posit.co/r/getstarted/shiny-basics/lesson1/)
- [shinyjs](https://deanattali.com/shinyjs/)
- [stringr](https://stringr.tidyverse.org/)

## 📄 License

- [MIT](https://opensource.org/license/mit)