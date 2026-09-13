# What’s happening (root cause)

After you press Clear all selections, your UI looks reset, but one of the filter inputs can still hold a stale value on the server (most commonly input$library_search, sometimes input$service_filter too).

Then when you pick a new city:

Your map observer runs.

It applies filters in this order: city → service → library_search.

If input$library_search is still an old library id (from the previous city), the final filter makes data become 0 rows.

This line aborts the whole map update:

```r
req(nrow(data) > 0)
```

When an observeEvent() errors/aborts like that, Leaflet stays showing the previous map, which matches your symptom: “city shows selected but map doesn’t change”.

So the app isn’t “ignoring the city”; it’s failing to render due to empty data caused by a stale library selection, and your req() hides that failure.

## Step-by-step plan to fix it

Guarantee library_search is valid whenever city/service changes:

If the currently-selected library isn’t in the newly computed choices, reset it to "".

Make the map observer robust to 0 rows:

Instead of req(nrow(data) > 0), either:

clear the map / show notification, or

automatically drop the invalid library_search filter and re-render.

(Optional but recommended) Add a quick debug print so you can see when it happens.

Default assumptions I’m making:

The stale value is primarily input$library_search (Selectize is the usual culprit).

The city change does fire the observers; the map doesn’t change because the observer aborts at req(nrow(data) > 0).

If you have an example of “good behavior” (a version/commit where city switching always works), share the relevant diff and I’ll tailor the smallest possible patch.

### Fix 1: Reset library_search when it becomes invalid (best first move)

In your city → cascade observer, after you compute lib_choices, add:

```r
# After updateSelectizeInput(...)
current_lib <- isolate(input$library_search)
valid_lib_ids <- c("", names(lib_choices))  # because lib_choices is setNames(id, label)
# Careful: your lib_choices is setNames(as.character(id), branch_name),
# so the *values* are ids. We'll validate against those instead:
valid_lib_values <- c("", unname(lib_choices))

updateSelectizeInput(session, "library_search",
  choices = c("All Libraries" = "", lib_choices),
  server = TRUE,
  selected = if (!is.null(current_lib) && current_lib %in% valid_lib_values) current_lib else ""
)
```

Do the same in the service → cascade observer (because service changes can also invalidate the selected library):

```r
current_lib <- isolate(input$library_search)
valid_lib_values <- c("", unname(lib_choices))

updateSelectizeInput(session, "library_search",
  choices = c("All Libraries" = "", lib_choices),
  server = TRUE,
  selected = if (!is.null(current_lib) && current_lib %in% valid_lib_values) current_lib else ""
)
```

Why this works:

It prevents the server from holding onto a library id that no longer exists under the new city/service combination.

That stops data from ever becoming empty just because of a stale library_search.

### Fix 2: Don’t let the map silently “stick” when data is empty

Replace:

```r
req(nrow(data) > 0)
```

with something that still updates the UI. Two good patterns:

#### Option A: Auto-clear invalid library filter and retry once

Right before the req(nrow(data) > 0):

```r
if (nrow(data) == 0 && !is.null(input$library_search) && input$library_search != "") {
  updateSelectizeInput(session, "library_search", selected = "")
  return()
}
```

Then keep req(nrow(data) > 0) after it.

This is pragmatic: if the only reason you have 0 rows is a stale library id, you self-heal immediately.

#### Option B: Show “no results” and render an empty city view

Instead of aborting, do:

```r
if (nrow(data) == 0) {
  showNotification("No libraries match the current filters.", type = "warning", duration = 3)
  leafletProxy("map") %>% clearMarkers() %>% clearControls()
  return()
}
```

### Minimal “most likely to fix your exact bug” patch

If you want the smallest change that targets the symptom you described:

In city_filter observer, change your updateSelectizeInput() call to include selected = "":

updateSelectizeInput(session, "library_search",
  choices = c("All Libraries" = "", lib_choices),
  server = TRUE,
  selected = ""
)

This is blunt (it always resets library choice when city changes), but it matches typical UX and prevents the stale-id → empty-data → stuck-map chain entirely.

Then optionally add the map observer safeguard (Fix 2) so you never get a “stuck” map again even if some future input goes stale.

### Quick way to confirm in 10 seconds (optional debugging)

Add this inside your map observer right before req(nrow(data) > 0):

```r
cat("MAP UPDATE | city=", input$city_filter,
    " service=", input$service_filter,
    " lib=", input$library_search,
    " n=", nrow(data), "\n")
```

Reproduce the bug. If you see lib=<some id> and n=0 right after changing city, that confirms it.
