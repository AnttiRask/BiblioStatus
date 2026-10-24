# Links made from text in the library data. A library's address, phone and
# e-mail come from the Kirkanta API; only what is safe as a link target becomes
# a link (a `javascript:` URL in a popup would run in the visitor's page).

test_that("safe_http_url accepts http and https addresses only", {
  expect_equal(safe_http_url("https://www.helsinki.fi/kirjasto"), "https://www.helsinki.fi/kirjasto")
  expect_equal(safe_http_url("http://example.fi/a?b=1&c=2"), "http://example.fi/a?b=1&c=2")
  expect_equal(safe_http_url("  HTTPS://Example.fi  "), "HTTPS://Example.fi")   # trimmed, scheme case ignored
  expect_true(all(is.na(safe_http_url(c(
    "javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,<script>alert(1)</script>",
    "vbscript:x", "//evil.example/x", "ftp://example.fi", "example.fi", "", NA,
    "https://example.fi/a b", "https://example.fi/<script>", "https://example.fi/\"onmouseover=\"x"
  )))))
})

test_that("safe_http_url is vector-safe and keeps the order", {
  expect_equal(safe_http_url(c("https://a.fi", "javascript:1", NA, "http://b.fi")),
               c("https://a.fi", NA, NA, "http://b.fi"))
})

test_that("safe_tel_href accepts phone numbers as they are written in the data", {
  expect_equal(safe_tel_href("02 623 4200"), "026234200")
  expect_equal(safe_tel_href("(014) 267 1249"), "0142671249")
  expect_equal(safe_tel_href("+358 9 310 1234"), "+35893101234")
  expect_equal(safe_tel_href("044-416 3525"), "0444163525")
})

test_that("safe_tel_href refuses what is not a phone number", {
  for (x in c("ma-pe 9-15", "javascript:alert(1)", "02 623 4200 ; rm", "0", "1234", "+", "",
              "12345678901234567890", NA, "02 623 4200 / asiakaspalvelu")) {
    expect_true(is.na(safe_tel_href(x)), info = x)
  }
})

test_that("safe_mailto_address accepts plain addresses and refuses anything else", {
  expect_equal(safe_mailto_address("kirjasto@pori.fi"), "kirjasto@pori.fi")
  expect_equal(safe_mailto_address("etu.suku@kirjasto.lahti.fi"), "etu.suku@kirjasto.lahti.fi")
  for (x in c("a@b.fi?subject=x", "a@b.fi&bcc=evil@x.fi", "a@b.fi, c@d.fi", "<a@b.fi>",
              "a b@c.fi", "a@b", "@b.fi", "a@@b.fi", "javascript:alert(1)", "", NA)) {
    expect_true(is.na(safe_mailto_address(x)), info = x)
  }
})

test_that("a popup links the name only for an http(s) address", {
  popup <- function(url) build_library_popup(url, "Oodi", "Street 1", "Open", 60.17, 24.94, opening_hours = "08:00 - 20:00")
  expect_match(popup("https://oodihelsinki.fi"), "<a href='https://oodihelsinki.fi'", fixed = TRUE)
  expect_false(grepl("javascript", popup("javascript:alert(1)"), fixed = TRUE))
  expect_match(popup("javascript:alert(1)"), "<b>Oodi</b>", fixed = TRUE)    # the name, without a link
  expect_match(popup(NA_character_), "<b>Oodi</b>", fixed = TRUE)
})

test_that("a popup for several libraries decides the link per library", {
  html <- build_library_popup(
    c("https://a.fi", "javascript:1"), c("A", "B"), c("x", "y"), c("Open", "Open"),
    c(60.1, 60.2), c(24.9, 24.8), opening_hours = c("08:00", "09:00")
  )
  expect_match(html[1], "<a href='https://a.fi'", fixed = TRUE)
  expect_false(grepl("<a href='javascript", html[2], fixed = TRUE))
})

# ---- the details panel ----

panel_library <- function(phone, email) {
  data.frame(id = 1, library_branch_name = "Oodi", lat = 60.17, lon = 24.94, city_name = "Helsinki",
             library_url = "https://oodihelsinki.fi", library_phone = phone, library_email = email,
             library_address = "Street 1", open_status = "Open", opening_hours = "08:00 - 20:00",
             stringsAsFactors = FALSE)
}

panel_html <- function(phone, email, env = parent.frame()) {
  # The server loads its data when the session starts: give it fixtures, not the real database
  names_replaced <- c("fetch_libraries", "fetch_schedules", "fetch_library_services")
  was_global <- vapply(names_replaced, exists, logical(1), envir = globalenv(), inherits = FALSE)
  originals <- mget(names_replaced, envir = globalenv(), inherits = TRUE)
  assign("fetch_libraries", function() panel_library(phone, email), envir = globalenv())
  assign("fetch_schedules", function() data.frame(library_id = numeric(), date = character(), from = character(),
    to = character(), status_label = character(), stringsAsFactors = FALSE), envir = globalenv())
  assign("fetch_library_services", function() data.frame(library_id = numeric(), service_name = character()), envir = globalenv())
  withr::defer(for (name in names_replaced) {
    if (was_global[[name]]) assign(name, originals[[name]], envir = globalenv()) else rm(list = name, envir = globalenv())
  }, envir = env)

  out <- NULL
  testServer(server, {
    session$flushReact()
    library_services_data(data.frame(library_id = 1, service_name = "Sauna", stringsAsFactors = FALSE))
    all_library_schedules(data.frame(library_id = 1, date = "2026-10-24", from = "08:00", to = "20:00",
                                     status_label = "Open", stringsAsFactors = FALSE))
    selected_library(panel_library(phone, email))
    session$flushReact()
    out <<- paste(as.character(output$library_services$html), collapse = "")
  })
  out
}

test_that("the details panel links a phone number and an address that are what they should be", {
  html <- panel_html("(014) 267 1249", "kirjasto@pori.fi")
  expect_match(html, 'href="tel:0142671249"', fixed = TRUE)
  expect_match(html, 'href="mailto:kirjasto@pori.fi"', fixed = TRUE)
})

test_that("the details panel shows what it can't link as plain text", {
  html <- panel_html("ma-pe 9-15", "a@b.fi?bcc=evil@x.fi")
  expect_false(grepl("tel:", html, fixed = TRUE))
  expect_false(grepl("mailto:", html, fixed = TRUE))
  expect_match(html, "ma-pe 9-15", fixed = TRUE)
  expect_match(html, "a@b.fi?bcc=evil@x.fi", fixed = TRUE)
})

test_that("links that open a new tab don't hand over the page", {
  html <- panel_html("02 623 4200", "kirjasto@pori.fi")
  expect_match(html, 'target="_blank" rel="noopener noreferrer"', fixed = TRUE)
})

test_that("the e-mail link uses the checked address (trimmed), not the raw text", {
  html <- panel_html("02 623 4200", "  kirjasto@pori.fi ")
  expect_match(html, 'href="mailto:kirjasto@pori.fi"', fixed = TRUE)
})
