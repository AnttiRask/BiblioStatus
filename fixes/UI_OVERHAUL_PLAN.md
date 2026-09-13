# BiblioStatus UI Overhaul Plan

## Context

Multiple UI improvements across Library Map and Service Statistics tabs.
The library services normalization is complete; now addressing usability,
layout, filter UX, and visualization polish.

---

## Files to Modify

- `app/ui.R` — layout restructure, filter inputs, dark mode placement
- `app/server.R` — filter logic, cascading updates, city default "All"
- `app/modules/service_stats.R` — ggplot theme, dark mode support
- `app/www/styles.css` — footer z-index, sidebar scroll, map height

---

## Library Map Tab

### 1. Dark mode toggle → navbar (top-right)

Remove `input_dark_mode(...)` from the sidebar.
Add to `page_navbar()` after the two `nav_panel()` calls:

```r
nav_spacer(),
nav_item(input_dark_mode(id = "dark_mode", mode = "light"))
```

### 2. Title text → above the map

Remove from sidebar:

- `h3("BiblioStatus")`
- `p("Which Finnish Libraries Are Open Right Now?")`
- the `br()` that follows

Add above `leafletOutput("map", ...)` in the main content area:

```r
h4("Which Finnish Libraries Are Open Right Now?",
   style = "margin: 12px 16px 4px; font-weight: 600;")
```

### 3. Filter inputs

| Input | Change |
|---|---|
| `city_filter` | Keep as `selectInput`; default to `"All Cities" = ""` instead of Helsinki |
| `library_search` | Replace `textInput` with `selectizeInput("library_search", "Select Library:", choices = NULL, options = list(placeholder = "All Libraries"))` |
| `service_filter` | Keep as `selectInput`; rename label from "Filter by Service:" to "Select Service:" |

Add clear button after the three filters, before Find Nearest:

```r
actionButton(
  "clear_filters", NULL,
  icon  = icon("rotate-left"),
  class = "btn btn-sm btn-outline-secondary mb-2",
  title = "Clear all filters"
)
```

### 4. Map height

Change `leafletOutput("map", height = "85vh")` → `height = "calc(100vh - 56px)"`.

---

## server.R Changes

### City default: "All"

```r
updateSelectInput(session, "city_filter",
  choices  = c("All Cities" = "", city_choices),
  selected = "")   # was "Helsinki"
```

### Map observer: handle empty city filter

```r
data <- if (!is.null(input$city_filter) && input$city_filter != "") {
  library_data() %>% filter(city_name == input$city_filter)
} else {
  library_data()
}
```

### Library selectize: initial population

Add alongside city population in the startup `observe()`:

```r
lib_choices <- library_data() %>%
  arrange(library_branch_name) %>%
  { setNames(.$id, .$library_branch_name) }
updateSelectizeInput(session, "library_search",
  choices = c("All Libraries" = "", lib_choices), server = TRUE)
```

### Library selection handler

Replace the existing text-search `observeEvent(input$library_search, ...)` with:

```r
observeEvent(input$library_search, {
  req(input$library_search != "")
  selected_lib <- library_data() %>%
    filter(id == as.numeric(input$library_search))
  req(nrow(selected_lib) > 0)
  updateSelectInput(session, "city_filter", selected = selected_lib$city_name[1])
  leafletProxy("map") %>%
    setView(lng = selected_lib$lon[1], lat = selected_lib$lat[1], zoom = 15)
}, ignoreInit = TRUE)
```

### Cascading: city → narrow library + service choices

```r
observeEvent(input$city_filter, {
  all_libs <- library_data()
  all_svcs <- library_services_data()
  req(all_libs, all_svcs)
  if (!is.null(input$city_filter) && input$city_filter != "") {
    valid_ids   <- all_libs %>% filter(city_name == input$city_filter) %>% pull(id)
    lib_choices <- all_libs %>% filter(id %in% valid_ids) %>%
      arrange(library_branch_name) %>% { setNames(.$id, .$library_branch_name) }
    svc_choices <- all_svcs %>% filter(library_id %in% valid_ids) %>%
      pull(service_name) %>% unique() %>% sort()
  } else {
    lib_choices <- all_libs %>% arrange(library_branch_name) %>%
      { setNames(.$id, .$library_branch_name) }
    svc_choices <- all_svcs %>% pull(service_name) %>% unique() %>% sort()
  }
  updateSelectizeInput(session, "library_search",
    choices = c("All Libraries" = "", lib_choices), server = TRUE, selected = "")
  updateSelectInput(session, "service_filter",
    choices = c("All Services" = "", svc_choices), selected = "")
}, ignoreInit = TRUE)
```

### Cascading: service → narrow city + library choices

```r
observeEvent(input$service_filter, {
  all_libs <- library_data()
  all_svcs <- library_services_data()
  req(all_libs, all_svcs)
  if (!is.null(input$service_filter) && input$service_filter != "") {
    valid_ids   <- all_svcs %>%
      filter(service_name == input$service_filter) %>% pull(library_id)
    valid_libs  <- all_libs %>% filter(id %in% valid_ids)
    city_choices <- valid_libs %>% pull(city_name) %>% unique() %>% sort()
    lib_choices  <- valid_libs %>% arrange(library_branch_name) %>%
      { setNames(.$id, .$library_branch_name) }
  } else {
    city_choices <- all_libs %>% pull(city_name) %>% unique() %>% sort()
    lib_choices  <- all_libs %>% arrange(library_branch_name) %>%
      { setNames(.$id, .$library_branch_name) }
  }
  updateSelectInput(session, "city_filter",
    choices = c("All Cities" = "", city_choices), selected = "")
  updateSelectizeInput(session, "library_search",
    choices = c("All Libraries" = "", lib_choices), server = TRUE, selected = "")
}, ignoreInit = TRUE)
```

**Note:** Cascade updates only the *choices* of other filters, not their *values*, to avoid
reactive loops. The only exception is `selected = ""` on the city/library when service changes
(and vice versa), which is intentional reset behaviour.

### Clear button

```r
observeEvent(input$clear_filters, {
  all_libs    <- library_data()
  all_svcs    <- library_services_data()
  city_choices <- all_libs %>% pull(city_name) %>% unique() %>% sort()
  svc_choices  <- all_svcs %>% pull(service_name) %>% unique() %>% sort()
  lib_choices  <- all_libs %>% arrange(library_branch_name) %>%
    { setNames(.$id, .$library_branch_name) }
  updateSelectInput(session, "city_filter",
    choices = c("All Cities" = "", city_choices), selected = "")
  updateSelectizeInput(session, "library_search",
    choices = c("All Libraries" = "", lib_choices), server = TRUE, selected = "")
  updateSelectInput(session, "service_filter",
    choices = c("All Services" = "", svc_choices), selected = "")
  selected_library(NULL)
})
```

### Housekeeping

- Delete the old standalone `observe()` that populated `service_filter` (lines ~137–154)
- Update `service_stats_server` call to pass `dark_mode`:

```r
service_stats_server("stats", library_services_data, library_data,
                     reactive(input$dark_mode))
```

---

## Service Statistics Tab

### ggplot overhaul (`service_stats.R`)

Update function signature to accept `dark_mode` reactive:

```r
service_stats_server <- function(id, library_services, libraries, dark_mode) {
```

Replace `renderPlot` body with:

```r
is_dark    <- isTRUE(dark_mode())
bg_color   <- if (is_dark) "#191414" else "#FFFFFF"
text_color <- if (is_dark) "#FFFFFF" else "#1a1a1a"

ggplot(data, aes(x = reorder(service_name, library_count), y = library_count)) +
  geom_col(fill = "#C1272D") +
  geom_text(aes(label = library_count), hjust = -0.2, size = 3.5, color = text_color) +
  coord_flip() +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(
    title = if (!is.null(input$stats_city) && input$stats_city != "")
              paste("Most Common Services in", input$stats_city)
            else "Most Common Library Services (All Cities)",
    x = NULL, y = NULL
  ) +
  theme_minimal() +
  theme(
    text             = element_text(color = text_color),
    axis.text.y      = element_text(size = 11, color = text_color),
    axis.text.x      = element_blank(),
    axis.ticks       = element_blank(),
    panel.grid       = element_blank(),
    plot.background  = element_rect(fill = bg_color, color = NA),
    panel.background = element_rect(fill = bg_color, color = NA),
    plot.title       = element_text(size = 14, face = "bold", color = text_color)
  )
```

---

## CSS Changes (`styles.css`)

### Footer z-index (fix overlap on Service Statistics tab)

```css
.app-footer {
  position: relative;
  z-index: 10;
}
```

### Sidebar: independent scroll so map can be taller

```css
.bslib-sidebar-layout > .sidebar > .sidebar-content {
  max-height: calc(100vh - 56px);
  overflow-y: auto;
}
```

---

## Verification Checklist

- [ ] Map loads showing all libraries (no city pre-selected)
- [ ] Dark mode toggle appears in navbar top-right
- [ ] "Which Finnish Libraries Are Open Right Now?" is above the map
- [ ] Select Library dropdown supports type-to-search; selecting a library sets the city and zooms map
- [ ] Selecting a city narrows the library and service dropdowns
- [ ] Selecting a service narrows the city and library dropdowns
- [ ] Clear button resets all three filters and closes the sidebar panel
- [ ] Service Statistics: red bars (#C1272D), no grid, no x-axis numbers, data labels at bar ends
- [ ] Visualization follows dark/light mode toggle
- [ ] Footer no longer overlaps the chart
