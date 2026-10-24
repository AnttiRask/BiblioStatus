// Light/dark switch (see mode_toggle_button() in functions.R). The page starts in
// light mode; a click flips Bootstrap's data-bs-theme on <html>. The icon is
// swapped by CSS, and the button's label names the mode a click switches to. The
// server reads the mode from the Shiny input `dark_mode` ("light" / "dark"), as it
// did with bslib's own switch; app.js watches the attribute for the statistics
// chart (`is_dark_mode`).
(function () {
  var root = document.documentElement;

  // Set straight away (this script is in the head) so the page never flashes
  root.setAttribute("data-bs-theme", "light");

  function isDark() {
    return root.getAttribute("data-bs-theme") === "dark";
  }

  function setLabel(button) {
    var label = button.getAttribute(isDark() ? "data-label-to-light" : "data-label-to-dark");
    button.setAttribute("aria-label", label);
    button.setAttribute("title", label);
  }

  function publish() {
    Shiny.setInputValue("dark_mode", isDark() ? "dark" : "light");
  }

  // Also after a reconnect: the new session starts without knowing the mode
  $(document).on("shiny:connected", publish);

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.getElementById("mode-toggle");
    if (!button) return;

    setLabel(button);
    button.addEventListener("click", function () {
      root.setAttribute("data-bs-theme", isDark() ? "light" : "dark");
      setLabel(button);
      if (window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected()) publish();
    });
  });
})();
