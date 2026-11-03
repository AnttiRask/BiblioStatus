// Client-side behaviour: reports mobile / dark-mode state and the startup
// location to Shiny, and answers the "Find Nearest" geolocation request.
//
// Everything below touches the Shiny global, which isn't defined yet this early
// in <head>: Shiny's own JS bundle loads later, near the end of <body>.
// Registering handlers or calling Shiny.setInputValue before then throws
// "Shiny.setInputValue is not a function" and silently aborts the rest of the
// script (including the addCustomMessageHandler calls), breaking Find Nearest
// and other input reporting. So the whole block waits for Shiny.
// A 'shiny:connected' listener can't be used for that: Shiny fires it through
// jQuery's trigger(), which native addEventListener never receives, and jQuery
// itself isn't guaranteed to be loaded yet either. Polling for
// window.Shiny.setInputValue needs no other library.
function onShinyReady(callback) {
  if (window.Shiny && typeof Shiny.setInputValue === 'function') {
    callback();
    return;
  }
  var intervalId = setInterval(function() {
    if (window.Shiny && typeof Shiny.setInputValue === 'function') {
      clearInterval(intervalId);
      callback();
    }
  }, 50);
}

onShinyReady(function() {
  // Geolocation timing (ms) comes from geo_config in app/lib/variables.R via
  // window.BIBLIO_CONFIG (set by ui.R). Startup uses a coarse/cached location
  // for a fast first paint; Find Nearest waits longer for a precise, fresh fix.
  const STARTUP_GEO_TIMEOUT_MS = BIBLIO_CONFIG.startupTimeoutMs;
  const STARTUP_GEO_MAX_AGE_MS = BIBLIO_CONFIG.startupMaxAgeMs;
  const STARTUP_GEO_FALLBACK_MS = BIBLIO_CONFIG.startupFallbackMs;
  const FIND_NEAREST_GEO_TIMEOUT_MS = BIBLIO_CONFIG.findNearestTimeoutMs;
  const FIND_NEAREST_GEO_MAX_AGE_MS = BIBLIO_CONFIG.findNearestMaxAgeMs;

  // Watch for dark mode changes (the data-bs-theme attribute on <html>, set by mode-toggle.js)
  var darkModeObserver = new MutationObserver(function(mutations) {
    mutations.forEach(function(mutation) {
      if (mutation.attributeName === 'data-bs-theme') {
        var isDark = document.documentElement.getAttribute('data-bs-theme') === 'dark';
        Shiny.setInputValue('is_dark_mode', isDark, {priority: 'event'});
      }
    });
  });
  darkModeObserver.observe(document.documentElement, { attributes: true });

  $(document).on('shiny:sessioninitialized', function() {
    Shiny.setInputValue('is_mobile', /iPhone|iPad|iPod|Android/i.test(navigator.userAgent), {priority: 'event'});

    // Report initial dark mode state
    var isDark = document.documentElement.getAttribute('data-bs-theme') === 'dark';
    Shiny.setInputValue('is_dark_mode', isDark, {priority: 'event'});

    // Request geolocation on startup to determine nearest city
    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(
        function(position) {
          Shiny.setInputValue('startup_location', {
            lat: position.coords.latitude,
            lon: position.coords.longitude
          }, {priority: 'event'});
        },
        function(error) {
          Shiny.setInputValue('startup_geolocation_failed', true, {priority: 'event'});
        },
        { enableHighAccuracy: false, timeout: STARTUP_GEO_TIMEOUT_MS, maximumAge: STARTUP_GEO_MAX_AGE_MS }
      );
    } else {
      Shiny.setInputValue('startup_geolocation_failed', true, {priority: 'event'});
    }

    // Fallback: if startup location still not received, use Helsinki
    setTimeout(function() {
      Shiny.setInputValue('startup_geolocation_timeout', true, {priority: 'event'});
    }, STARTUP_GEO_FALLBACK_MS);
  });

  // Geolocation handler for finding nearest library (Find Nearest button)
  Shiny.addCustomMessageHandler('requestGeolocation', function(message) {
    if (!navigator.geolocation) {
      Shiny.setInputValue('geolocation_error',
        BIBLIO_CONFIG.messages.geolocationUnsupported,
        {priority: 'event'});
      return;
    }

    Shiny.setInputValue('geolocation_loading', true, {priority: 'event'});

    navigator.geolocation.getCurrentPosition(
      function(position) {
        Shiny.setInputValue('user_location', {
          lat: position.coords.latitude,
          lon: position.coords.longitude
        }, {priority: 'event'});
        Shiny.setInputValue('geolocation_loading', false, {priority: 'event'});
      },
      function(error) {
        var errorMsg = error.code === 1 ?
          BIBLIO_CONFIG.messages.geolocationDenied :
          BIBLIO_CONFIG.messages.geolocationFailed;
        Shiny.setInputValue('geolocation_error', errorMsg, {priority: 'event'});
        Shiny.setInputValue('geolocation_loading', false, {priority: 'event'});
      },
      { enableHighAccuracy: true, timeout: FIND_NEAREST_GEO_TIMEOUT_MS, maximumAge: FIND_NEAREST_GEO_MAX_AGE_MS }
    );
  });

  // The connection to the server is gone for good. The server reconnects a dropped
  // websocket by itself (session$allowReconnect("force") in server.R), which takes about
  // 2 s, so the message only appears if no reconnect has happened after
  // BIBLIO_CONFIG.sessionEndedAfterMs; Shiny itself only greys the page out and the
  // page looks frozen. A reconnect that comes later takes the message away. The page
  // is never reloaded on its own. Closing or reloading the page also closes the
  // connection: that is not a lost session.
  (function() {
    var unloading = false;
    var timer = null;
    window.addEventListener('beforeunload', function() { unloading = true; });
    window.addEventListener('pagehide', function() { unloading = true; });
    window.addEventListener('pageshow', function() { unloading = false; });

    function hide() {
      var box = document.getElementById('session-ended');
      if (box) box.remove();
    }

    function show() {
      if (document.getElementById('session-ended')) return;
      var box = document.createElement('div');
      box.id = 'session-ended';
      box.setAttribute('role', 'alertdialog');
      box.setAttribute('aria-labelledby', 'session-ended-title');

      var title = document.createElement('h2');
      title.id = 'session-ended-title';
      title.textContent = BIBLIO_CONFIG.messages.sessionEndedTitle;

      var text = document.createElement('p');
      text.textContent = BIBLIO_CONFIG.messages.sessionEndedText;

      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'btn btn-primary';
      button.textContent = BIBLIO_CONFIG.messages.sessionEndedReload;
      button.addEventListener('click', function() { window.location.reload(); });

      box.appendChild(title);
      box.appendChild(text);
      box.appendChild(button);
      document.body.appendChild(box);
      button.focus();
    }

    $(document).on('shiny:disconnected', function() {
      if (unloading || timer) return;
      timer = setTimeout(function() { timer = null; show(); }, BIBLIO_CONFIG.sessionEndedAfterMs);
    });

    $(document).on('shiny:connected', function() {
      clearTimeout(timer);
      timer = null;
      hide();
    });
  })();
});
