(function () {
  "use strict";

  var root = document.documentElement;
  var tabs = document.querySelectorAll(".seg");
  var shots = { a: document.getElementById("shot-a"), b: document.getElementById("shot-b") };
  var cassette = document.getElementById("cassette");

  function setSide(side) {
    root.setAttribute("data-side", side);
    tabs.forEach(function (tab) {
      tab.setAttribute("aria-selected", tab.dataset.side === side ? "true" : "false");
    });
    Object.keys(shots).forEach(function (key) {
      if (shots[key]) shots[key].hidden = key !== side;
    });
  }

  function currentSide() {
    return root.getAttribute("data-side") === "b" ? "b" : "a";
  }

  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      setSide(tab.dataset.side);
    });
    tab.addEventListener("keydown", function (event) {
      if (event.key === "ArrowRight" || event.key === "ArrowLeft") {
        event.preventDefault();
        var next = currentSide() === "a" ? "b" : "a";
        setSide(next);
        document.getElementById("tab-" + next).focus();
      }
    });
  });

  if (cassette) {
    cassette.addEventListener("click", function () {
      setSide(currentSide() === "a" ? "b" : "a");
    });
  }

  // Copy buttons
  document.querySelectorAll(".copy").forEach(function (button) {
    button.addEventListener("click", function () {
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(button.dataset.copy).then(function () {
        var original = button.textContent;
        button.textContent = "Copied";
        setTimeout(function () {
          button.textContent = original;
        }, 1600);
      });
    });
  });

  // Latest release: version label and direct DMG link.
  fetch("https://api.github.com/repos/sozercan/kaset/releases/latest", {
    headers: { Accept: "application/vnd.github+json" },
  })
    .then(function (response) {
      if (!response.ok) throw new Error("release lookup failed");
      return response.json();
    })
    .then(function (release) {
      var version = (release.tag_name || "").replace(/^v/, "");
      if (!version) return;

      var dmg = (release.assets || []).find(function (asset) {
        return /\.dmg$/i.test(asset.name);
      });

      document.querySelectorAll("[data-version]").forEach(function (el) {
        el.textContent = "Version " + version;
      });
      document.querySelectorAll("[data-version-short]").forEach(function (el) {
        el.textContent = version;
      });
      if (dmg) {
        document.querySelectorAll("[data-download]").forEach(function (link) {
          link.href = dmg.browser_download_url;
        });
      }
    })
    .catch(function () {
      // Keep the generic /releases/latest links.
    });
})();
