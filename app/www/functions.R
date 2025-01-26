# Updated functions.R

# Function to fetch the list of libraries from Kirjastot.fi API ----
fetch_libraries <- function(session_data) {
    if (!is.null(session_data$libraries)) {
        return(session_data$libraries)
    }
    api_url <- "https://api.kirjastot.fi/v4/library"
    response <- GET(
        api_url,
        query = list(
            city.name = "Helsinki",
            type = "municipal",
            limit = 100
        )
    )
    
    if (status_code(response) == 200) {
        content_text <- content(response, "text", encoding = "UTF-8")
        data <- fromJSON(content_text, flatten = TRUE)
        
        if (!is.null(data$items) && is.data.frame(data$items)) {
            libraries <- data$items %>% 
                transmute(
                    id,
                    library_branch_name = name,
                    lat = coordinates.lat,
                    lon = coordinates.lon
                ) %>%
                filter(!is.na(lat) & !is.na(lon) & id != 84923)  # Exclude Monikielinen kirjasto
            session_data$libraries <- libraries  # Store in reactiveValues
            return(libraries)
        } else {
            stop("Invalid response: 'items' field is missing or not a data frame in the API response.")
        }
    } else {
        stop("Failed to fetch libraries: ", status_code(response))
    }
}

# Function to fetch schedules for libraries ----
fetch_schedules <- function(libraries, session_data) {
    if (!is.null(session_data$schedules)) {
        return(session_data$schedules)
    }
    
    api_url <- "https://api.kirjastot.fi/v4/schedules"
    
    updated_status <- purrr::map_dfr(
        seq_len(nrow(libraries)),
        ~ {
            library_id <- libraries$id[.x]
            
            response <- GET(api_url, query = list(library = library_id, date = Sys.Date()))
            
            if (status_code(response) == 200) {
                content_text <- content(response, "text", encoding = "UTF-8")
                data <- fromJSON(content_text, flatten = TRUE)
                
                # print(data)  # Debug
                
                if (!is.null(data$items) && nrow(data$items) > 0) {
                    closed <- data$items$closed[1]
                    
                    if (closed) {
                        return(tibble(id = library_id, open_status = "Closed for the whole day", opening_hours = NA_character_))
                    }
                    
                    times <- data %>%
                        pluck("items", "times", 1, .default = NULL)
                    
                    # print(times)  # Debug
                    
                    if (!is.null(times) && is.data.frame(times)) {
                        # Ensure times are character strings for comparison
                        times <- times %>%
                            mutate(
                                from = as.character(from),
                                to   = as.character(to)
                            )
                        
                        now <- format(Sys.time(), tz = "Europe/Helsinki", "%H:%M")
                        
                        # Filter only the row that corresponds to the current time
                        current_time_row <- times %>%
                            filter(from <= now & to >= now) %>%
                            slice(1)  # Take the first matching row, if multiple
                        
                        if (nrow(current_time_row) > 0) {
                            open_now <- current_time_row %>%
                                mutate(
                                    open_now = case_when(
                                        status == 0 ~ "Temporarily closed",
                                        status == 1 ~ "Open",
                                        status == 2 ~ "Self-service",
                                        TRUE        ~ "Unknown"
                                    )
                                ) %>% 
                                pull(open_now)
                            
                            opening_hours <- paste0(current_time_row$from, " - ", current_time_row$to)
                            
                            return(
                                tibble(
                                    id            = library_id,
                                    open_status   = open_now,
                                    opening_hours = opening_hours
                                )
                            )
                        } else {
                            # Handle libraries that are closed at the current time
                            return(tibble(id = library_id, open_status = "Closed", opening_hours = NA_character_))
                        }
                    }
                }
            }
            tibble(id = library_id, open_status = "Unknown", opening_hours = NA_character_)
        }
    )
    
    library_status <- libraries %>%
        left_join(updated_status, by = "id") %>%
        mutate(
            open_status = coalesce(open_status, "Unknown"),
            opening_hours = coalesce(opening_hours, NA_character_)
        )
    
    session_data$schedules <- library_status  # Store in reactiveValues
    return(library_status)
}
