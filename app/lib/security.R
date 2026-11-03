## Security headers for the HTML page.
##
## Shiny has no built-in hook for response headers (the `shiny.http.response.filter`
## option does nothing), so run.R wraps the app's page handler instead. Static
## assets are served by other handlers and don't need these headers.

# Hosts the page legitimately loads things from (keep in sync with
# map_tiles_host in variables.R)
map_tiles_host <- "https://services.arcgisonline.com"
font_host <- "https://fonts.cdnfonts.com"

# The Content-Security-Policy, enforced. It was report-only until 2026-10-24: a
# throwaway copy of the app recorded every violation the browser reported while
# the app was used (load, all dropdowns and the search box, All Cities with 719
# markers, popups, the details panel, dark mode, the statistics tab with its chart
# and table, a forced reconnect, Find Nearest, a phone-sized layout) and there
# were none; the recorder was checked with deliberate violations. The only
# external hosts the page uses are the two named below.
# Shiny and htmlwidgets use inline scripts and styles and eval, hence
# 'unsafe-inline' and 'unsafe-eval' (that limits what the policy protects against,
# but it still stops loading anything from other hosts). wss: is the Shiny
# websocket for browsers that don't count it as 'self'. frame-ancestors is the
# modern clickjacking protection (X-Frame-Options below is the fallback).
# If this ever breaks something, put the same string back under
# "Content-Security-Policy-Report-Only" to see what it blocks without blocking it.
csp_policy <- paste(
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
    paste("style-src 'self' 'unsafe-inline'", font_host),
    paste("font-src 'self' data:", font_host),
    paste("img-src 'self' data: blob:", map_tiles_host),
    "connect-src 'self' wss:",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "object-src 'none'",
    "form-action 'self'",
    sep = "; "
)

security_headers <- function() {
    list(
        "Content-Security-Policy"             = csp_policy,
        "X-Frame-Options"                     = "DENY",
        "X-Content-Type-Options"              = "nosniff",
        "Referrer-Policy"                     = "strict-origin-when-cross-origin",
        # The app only needs the user's location, and only for itself
        "Permissions-Policy"                  = "geolocation=(self), camera=(), microphone=(), payment=(), usb=()",
        # Cloud Run only serves HTTPS; one year, no subdomains, no preload
        "Strict-Transport-Security"           = "max-age=31536000"
    )
}

add_headers <- function(response, headers) {
    if (inherits(response, "httpResponse")) {
        for (name in names(headers)) {
            response$headers[[name]] <- headers[[name]]
        }
    }
    response
}

# Wrap a Shiny app object so every page response carries the headers. Handles
# the three things a handler can return: NULL, a response, or a promise.
with_security_headers <- function(app, headers = security_headers()) {
    original <- app$httpHandler
    app$httpHandler <- function(req) {
        res <- original(req)
        if (promises::is.promising(res)) {
            promises::then(res, function(value) add_headers(value, headers))
        } else {
            add_headers(res, headers)
        }
    }
    app
}
