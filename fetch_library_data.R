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
  response <- GET(
    api_url,
    query = list(
      type = "municipal",
      limit = 1000,
      with = "primaryContactInfo",
      with = "services"
    )
  )

  if (status_code(response) == 200) {
    data <- fromJSON(
      content(response, "text", encoding = "UTF-8"),
      flatten = TRUE
    )$items %>%
      mutate(
        library_services = map_chr(
          services,
          ~ {
            if (is.data.frame(.x) && "standardName" %in% names(.x)) {
              str_c(sort(unique(.x$standardName)), collapse = ", ")
            } else {
              NA_character_
            }
          }
        )
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
        library_address = paste(
          street_address,
          zip_code,
          city_name,
          sep = ", "
        ),
        # fmt: skip
        library_url = case_when(
            id == 85010 ~ 'https://sydankylat.fi/palvelut/tiistenjoen-kirjasto', # Tiistenjoen sivukirjasto
            id == 85014 ~ 'https://www.bibliotek.ax/-/lemlands-kommunbibliotek#/', # Lemland
            id == 85021 ~ 'https://larsmo.fi/fi/kulttuuri-ja-vapaa-aika/kirjasto/bosundin-kirjasto/', # Bosundin kirjasto
            id == 85023 ~ 'https://www.bibliotek.ax/-/eckero-kommunbibliotek#/', # Eckerön kirjasto
            id == 85032 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#85032', # Reposaaren kirjasto
            id == 85054 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#85054', # Suvilahden kirjasto
            id == 85094 ~ 'https://blanka.finna.fi/OrganisationInfo/Home#85094', # Korppoon kirjasto
            id == 85103 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#85103', # Ahlaisten kirjasto
            id == 85106 ~ 'https://kaskinen.fi/fi/vapaa-aika-ja-kulttuuri/kulttuuri/kirjasto', # Kaskisten kirjasto
            id == 85133 ~ 'https://hakemisto.kirjastot.fi/palkane/laitikkala', # Laitikkalan lainausasema
            id == 85188 ~ 'https://www.kirkkonummi.verkkokirjasto.fi/-/kirkkonummen-kirjastotalo-fyyri', # Pääkirjasto Kirjastotalo Fyyri
            id == 85215 ~ 'https://www.merijarvi.fi/sivistyspalvelut/kirjasto', # Merijärven kirjasto
            id == 85218 ~ 'https://www.bibliotek.ax/-/vardo-kommunbibliotek', # Vårdö
            id == 85236 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#85236', # Tammikaivon kirjasto
            id == 85243 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#85243', # Pohjoisväylän kirjasto
            id == 85253 ~ 'https://hakemisto.kirjastot.fi/kurikka/jurvan-kirjasto', # Jurvan kirjasto
            id == 85294 ~ 'https://fredrika.finna.fi/OrganisationInfo/Home#85294', # Pirttikylän kirjasto
            id == 85299 ~ 'https://fredrika.finna.fi/OrganisationInfo/Home#85299', # Ala-Ähtävän kirjasto
            id == 85306 ~ 'https://www.jyvaskyla.fi/?vesangan-lahikirjasto', # Vesangan lähikirjasto
            id == 85308 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#85308', # Vaasan pääkirjasto
            id == 85309 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#85309', # Palosaaren kirjasto
            id == 85319 ~ 'https://loisto.verkkokirjasto.fi/-/ylaneen-kirjasto#/', # Yläneen kirjasto
            id == 85331 ~ 'https://www.utsjoki.fi/vapaa-aika-ja-hyvinvointi/kirjasto/', # Pedar Jalvi kirjasto / Utsjoen kunnankirjasto
            id == 85340 ~ 'https://vanamo.finna.fi/OrganisationInfo/#85340', # Kalvolan kirjasto
            id == 85342 ~ 'https://vanamo.finna.fi/OrganisationInfo/#85342', # Nummen kirjasto
            id == 85358 ~ 'https://hakemisto.kirjastot.fi/palkane/aitoo', # Aitoon lainausasema
            id == 85376 ~ 'https://rutakko.verkkokirjasto.fi/-/iisalmen-kaupunginkirjasto', # Iisalmen kaupunginkirjasto
            id == 85425 ~ 'https://www.hausjarvi.fi/vapaa-aika-ja-matkailu/kirjasto/', # Hausjärven kirjasto
            id == 85507 ~ 'https://fredrika.finna.fi/OrganisationInfo/Home#85507', # Ylimarkun kirjasto
            id == 85519 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#85519', # Variskan kirjasto
            id == 85530 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#85530', # Pihlavan kirjasto
            id == 85531 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#85531', # Vähärauman kirjasto
            id == 85532 ~ 'https://www.aanekoski.fi/kulttuuri-ja-liikunta/kirjastot/suolahden-kirjasto', # Suolahden kirjasto
            id == 85551 ~ 'https://vanamo.finna.fi/OrganisationInfo/#85551', # Hämeenlinnan pääkirjasto
            id == 85557 ~ 'https://vanamo.finna.fi/OrganisationInfo/#85557', # Tuuloksen kirjasto
            id == 85558 ~ 'https://vanamo.finna.fi/OrganisationInfo/#85558', # Lammin kirjasto
            id == 85569 ~ 'https://hakemisto.kirjastot.fi/palkane/sappee', # Sappeen lainausasema
            id == 85624 ~ 'https://loisto.verkkokirjasto.fi/-/marttilan-kirjasto', # Marttilan kirjasto
            id == 85643 ~ 'https://larsmo.fi/fi/kulttuuri-ja-vapaa-aika/kirjasto/holmin-paakirjasto/', # Luodon pääkirjasto
            id == 85706 ~ 'https://fredrika.finna.fi/OrganisationInfo/Home#85706', # Närpiön pääkirjasto
            id == 85724 ~ 'https://www.aanekoski.fi/kulttuuri-ja-liikunta/kirjastot/sumiaisten-kirjasto', # Sumiaisten kirjasto
            id == 85754 ~ 'https://www.jyvaskyla.fi/?keltinmaen-lahikirjasto', # Keltinmäen lähikirjasto
            id == 85774 ~ 'https://keski.finna.fi/Content/kirjastot?leivonmaen-lahikirjasto', # Leivonmäen lähikirjasto
            id == 85789 ~ 'https://outi.finna.fi/OrganisationInfo/Home#85789', # Revonlahden lähikirjasto
            id == 85793 ~ 'https://www.bibliotek.ax/-/kokars-kommunbibliotek#/', # Kökar
            id == 85875 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#85875', # Sundomin omatoimikirjasto
            id == 85896 ~ 'https://lestijarvi.fi/vapaa-aika-ja-liikunta/kirjasto/', # Lestijärven kunnankirjasto
            id == 85920 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#85920', # Noormarkun kirjasto
            id == 85940 ~ 'https://vanamo.finna.fi/OrganisationInfo/#85940', # Rengon kirjasto
            id == 85959 ~ 'https://satakirjastot.finna.fi/OrganisationInfo/Home#85959', # Kullaan kirjasto
            id == 86020 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#86020', # Vähänkyrön omatoimikirjasto
            id == 86098 ~ 'https://www.jarvenpaa.fi/vapaa-aika-ja-harrastaminen/kirjasto', # Järvenpään kaupunginkirjasto
            id == 86326 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#86326', # Lavian kirjasto
            id == 86436 ~ 'https://www.bibliotek.ax/-/foglo-kommunbibliotek#/', # Föglö
            id == 86520 ~ 'https://satakirjastot.finna.fi/OrganisationInfo/Home#86520', # Nakkilan kirjasto
            id == 86522 ~ 'https://hakemisto.kirjastot.fi/karijoki/myrkyn-kirjasto', # Myrkyn kirjasto
            id == 86546 ~ 'https://blanka.finna.fi/OrganisationInfo/Home#86546', # Utön kirjasto
            id == 86555 ~ 'https://vaasankirjasto.finna.fi/OrganisationInfo/Home#86555', # Kohtaamispaikka Huudi
            id == 86634 ~ 'https://helle.finna.fi/OrganisationInfo/Home#86634', # Porlammin kirjasto (Lapinjärvi)
            id == 86649 ~ 'https://satakirjastot.finna.fi/OrganisationInfo#86649', # Itätuulen kirjasto
            id == 86725 ~ 'https://www.kuhmoinen.fi/vapaa-aika%20ja%20liikunta/kirjasto%20ja%20kulttuuri/kirjasto/', # Kuhmoisten kirjasto
            id == 86730 ~ 'https://outi.finna.fi/OrganisationInfo/Home#86730', # Oulun pääkirjasto
            id == 86768 ~ 'https://pyhajarvi.fi/fi/kirjasto', # Pyhäjärven kirjasto
            id == 86775 ~ 'https://eepos.finna.fi/OrganisationInfo/Home#86775', # Seinäjoen pääkirjasto, Aallon kirjasto
            id == 86784 ~ 'https://kirjasto.mikkeli.fi/', # Mikkelin pääkirjasto
            id == 86787 ~ 'https://lumme.finna.fi/OrganisationInfo/Home#86787', # Pertunmaan lähikirjasto
            id == 86788 ~ 'https://www.pyharanta.fi/vapaa-aika-ja-hyvinvointi/kirjasto/', # Pyhärannan kirjasto
            TRUE        ~ library_url
            )
      ) %>%
      # 84923 = Monikielinen kirjasto
      # 86072 = Kajaanin pääkirjaston lehtilukusali
      # 86636 = Kokkolan pääkirjaston lehtilukusali
      # 86653 = Valkeakosken kaupunginkirjaston lehtisali
      filter(
        !is.na(lat) & !is.na(lon) & !id %in% c(84923, 86072, 86636, 86653)
      ) %>%
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
