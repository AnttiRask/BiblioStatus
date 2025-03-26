library(dplyr)
library(here)
library(httr)
library(jsonlite)
library(purrr)
library(RSQLite)
library(stringr)

# Connect to SQLite
con <- dbConnect(
  SQLite(),
  dbname = here("app/libraries.sqlite"),
  read_only = FALSE
)

# Fetch libraries
fetch_libraries <- function() {
  api_url <- "https://api.kirjastot.fi/v4/library"
  response <- GET(api_url, query = list(type = "municipal", limit = 1000, with = "primaryContactInfo", with = "services"))

  if (status_code(response) == 200) {
    data <- fromJSON(
      content(response, "text", encoding = "UTF-8"),
      flatten = TRUE
    )$items %>% 
        mutate(
            library_services = map_chr(services, ~ {
                if (is.data.frame(.x) && "standardName" %in% names(.x)) {
                    str_c(.x$standardName, collapse = ", ")
                    } else {
                        NA_character_
                }
            })
        )
    
    libraries <- data %>%
      # fmt: skip
      transmute(
        id,
        library_branch_name = name,
        lat                 = coordinates.lat,
        lon                 = coordinates.lon,
        city_name           = address.city,
        zip_code            = address.zipcode,
        street_address      = address.street,
        library_url         = primaryContactInfo.homepage.url,
        library_services
      ) %>%
      # Fixing Seinäjoki main library coordinates, because there are two
      # buildings with different opening hours. Also adding coordinates for
      # the libraries that are missing them.
      mutate(
        lat = case_when(
          id == 85322 ~ 62.78559, # Seinäjoen pääkirjasto, Apila-kirjasto
          id == 85793 ~ 59.92259, # Kökar
          id == 86436 ~ 60.03090, # Föglö
          id == 86597 ~ 64.92256, # Kempeleen Linnakankaan kirjasto
          id == 86725 ~ 61.56385, # Kuhmoisten kirjasto
          id == 86775 ~ 62.78629, # Seinäjoen pääkirjasto, Aallon kirjasto
          id == 86784 ~ 61.68672, # Mikkelin pääkirjasto
          id == 86787 ~ 61.51729, # Pertunmaan lähikirjasto
          TRUE ~ lat
        ),
        lon = case_when(
          id == 85322 ~ 22.84204, # Seinäjoen pääkirjasto, Apila-kirjasto
          id == 85793 ~ 20.91381, # Kökar
          id == 86436 ~ 20.38677, # Föglö
          id == 86597 ~ 25.55812, # Kempeleen Linnakankaan kirjasto
          id == 86725 ~ 25.18183, # Kuhmoisten kirjasto
          id == 86775 ~ 22.84219, # Seinäjoen pääkirjasto, Aallon kirjasto
          id == 86784 ~ 27.27313, # Mikkelin pääkirjasto
          id == 86787 ~ 26.47860, # Pertunmaan lähikirjasto
          TRUE ~ lon
        ),
        library_address = paste(street_address, zip_code, city_name, sep = ", ")
      ) %>%
      # 84923 = Monikielinen kirjasto
      # 86072 = Kajaanin pääkirjaston lehtilukusali
      # 86636 = Kokkolan pääkirjaston lehtilukusali
      # 86653 = Valkeakosken kaupunginkirjaston lehtisali
      filter(!is.na(lat) & !is.na(lon) & !id %in% c(84923, 86072, 86636, 86653)) %>% 
        select(-c(street_address, zip_code))

    return(libraries)
  } else {
    stop("Failed to fetch libraries")
  }
}

# Fetch schedules
fetch_schedules <- function(libraries) {
  api_url <- "https://api.kirjastot.fi/v4/schedules"
  today <- format(Sys.Date(), tz = "Europe/Helsinki")

  schedules <- map_dfr(libraries$id, function(library_id) {
    response <- GET(api_url, query = list(library = library_id, date = today))

    if (status_code(response) == 200) {
      data <- fromJSON(
        content(response, "text", encoding = "UTF-8"),
        flatten = TRUE
      )$items

      if (length(data) == 0 || is.null(data$times)) {
        return(
          # fmt: skip
          tibble(
              library_id,
              date          = today,
              from          = NA_character_,
              to            = NA_character_,
              status_label  = "Unknown"
          )
        )
      }

      closed <- data$closed[1]

      if (closed) {
        return(
          # fmt: skip
          tibble(
              library_id,
              date          = today,
              from          = NA_character_,
              to            = NA_character_,
              status_label  = "Closed for the whole day"
          )
        )
      }

      times <- data$times[[1]]

      if (
        is.null(times) ||
          !all(c("from", "to") %in% names(times))
      ) {
        return(
          # fmt: skip
          tibble(
            library_id,
            date         = today,
            from         = NA_character_,
            to           = NA_character_,
            status_label = "Unknown"
          )
        )
      }

      times %>%
        # fmt: skip
        mutate(
          library_id   = library_id,
          date         = today,
          from         = as.character(from),
          to           = as.character(to),
          status_label = case_when(
            status == 0 ~ "Temporarily closed",
            status == 1 ~ "Open",
            status == 2 ~ "Self-service",
            TRUE ~ "Unknown"
          )
        ) %>%
        select(library_id, date, from, to, status_label)
    } else {
      # fmt: skip
      tibble(
        library_id,
        date         = today,
        from         = NA_character_,
        to           = NA_character_,
        status_label = "Unknown"
      )
    }
  })

  return(schedules)
}

# Execute fetching
libraries <- fetch_libraries()
schedules <- fetch_schedules(libraries)

# Write to SQLite
dbWriteTable(con, "libraries", libraries, overwrite = TRUE)
dbWriteTable(con, "schedules", schedules, overwrite = TRUE)

dbDisconnect(con)
