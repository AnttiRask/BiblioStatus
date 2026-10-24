source(here::here("app/www/security.R"))

test_that("the header set covers framing, referrers, permissions, transport and CSP", {
    h <- security_headers()
    expect_equal(h[["X-Frame-Options"]], "DENY")
    expect_equal(h[["X-Content-Type-Options"]], "nosniff")
    expect_equal(h[["Referrer-Policy"]], "strict-origin-when-cross-origin")
    expect_match(h[["Strict-Transport-Security"]], "^max-age=[0-9]+$")
    expect_false(grepl("includeSubDomains|preload", h[["Strict-Transport-Security"]]))
    expect_match(h[["Permissions-Policy"]], "geolocation=(self)", fixed = TRUE)
    expect_match(h[["Permissions-Policy"]], "camera=()", fixed = TRUE)
})

test_that("the CSP is enforced, in full, and there is no report-only copy of it", {
    h <- security_headers()
    csp <- h[["Content-Security-Policy"]]
    for (directive in c("default-src 'self'", "script-src", "style-src", "font-src", "img-src",
                        "connect-src", "frame-ancestors 'none'", "base-uri 'self'",
                        "object-src 'none'", "form-action 'self'")) {
        expect_match(csp, directive, fixed = TRUE)
    }
    expect_null(h[["Content-Security-Policy-Report-Only"]])
})

test_that("the CSP allows exactly the hosts the app uses", {
    csp <- security_headers()[["Content-Security-Policy"]]
    expect_match(csp, "img-src [^;]*https://services\\.arcgisonline\\.com")
    expect_false(grepl("cartocdn", csp))
    # the CSP host and the map's tile host are the same thing
    expect_match(csp, map_tiles_host, fixed = TRUE)
    expect_match(csp, "font-src [^;]*https://fonts\\.cdnfonts\\.com")
    expect_match(csp, "style-src [^;]*https://fonts\\.cdnfonts\\.com")
    expect_match(csp, "connect-src 'self' wss:", fixed = TRUE)
    # nothing is allowed from arbitrary hosts
    expect_false(grepl("\\*(;| |$)|https:(;| |$)", csp))
    # the only hosts named are the two the page loads from
    hosts <- unique(unlist(regmatches(csp, gregexpr("https://[a-z0-9.-]+", csp))))
    expect_setequal(hosts, c(map_tiles_host, font_host))
})

test_that("the policy loads nothing from other origins: scripts, styles, connections and frames", {
    csp <- security_headers()[["Content-Security-Policy"]]
    directive <- function(name) {
        m <- regmatches(csp, regexpr(paste0(name, " [^;]*"), csp))
        sub(paste0("^", name, " "), "", m)
    }
    expect_equal(directive("script-src"), "'self' 'unsafe-inline' 'unsafe-eval'")   # no external script host
    expect_false(grepl("https:", directive("script-src")))
    expect_false(grepl("https:", directive("connect-src")))
    expect_equal(directive("object-src"), "'none'")
    expect_false(grepl("frame-src", csp))                                            # falls back to default-src: no frames
})

fake_app <- function(handler) structure(list(httpHandler = handler), class = "shiny.appobj")

test_that("with_security_headers adds headers to page responses", {
    app <- with_security_headers(fake_app(function(req) {
        shiny::httpResponse(200, "text/html", "<p>hi</p>", headers = list("X-Existing" = "kept"))
    }))
    res <- app$httpHandler(list(PATH_INFO = "/"))
    expect_s3_class(res, "httpResponse")
    expect_equal(res$headers[["X-Frame-Options"]], "DENY")
    expect_equal(res$headers[["X-Existing"]], "kept")
    expect_equal(res$content, "<p>hi</p>")
})

test_that("with_security_headers leaves NULL and non-response values alone", {
    expect_null(with_security_headers(fake_app(function(req) NULL))$httpHandler(list()))
    expect_equal(with_security_headers(fake_app(function(req) "x"))$httpHandler(list()), "x")
})

test_that("with_security_headers works on promised responses", {
    app <- with_security_headers(fake_app(function(req) {
        promises::promise_resolve(shiny::httpResponse(200, "text/html", "ok"))
    }))
    out <- NULL
    promises::then(app$httpHandler(list()), function(v) out <<- v)
    for (i in 1:50) { later::run_now(); if (!is.null(out)) break }
    expect_s3_class(out, "httpResponse")
    expect_equal(out$headers[["X-Frame-Options"]], "DENY")
})
