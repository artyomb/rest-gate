(function () {
  "use strict";

  var AUTO_REFRESH_KEY = "restgate.logs.autoRefresh.v1";
  var AUTO_REFRESH_INTERVAL = 15000;

  function copyText(button) {
    var target = document.getElementById(button.dataset.copyTarget);
    if (!target) return;

    var text = target.textContent || "";
    var original = button.textContent;
    var done = function () {
      button.textContent = "Copied";
      window.setTimeout(function () { button.textContent = original; }, 1200);
    };

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done);
      return;
    }

    var textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.select();
    document.execCommand("copy");
    textarea.remove();
    done();
  }

  function formatRelativeTimes() {
    var formatter = new Intl.RelativeTimeFormat(undefined, {numeric: "auto"});
    document.querySelectorAll("time[data-relative-time]").forEach(function (element) {
      var date = new Date(element.dateTime);
      if (Number.isNaN(date.getTime())) return;

      var exact = element.textContent;
      var seconds = Math.round((date.getTime() - Date.now()) / 1000);
      var unit = "second";
      var divisor = 1;
      if (Math.abs(seconds) >= 86400) {
        unit = "day";
        divisor = 86400;
      } else if (Math.abs(seconds) >= 3600) {
        unit = "hour";
        divisor = 3600;
      } else if (Math.abs(seconds) >= 60) {
        unit = "minute";
        divisor = 60;
      }
      element.title = exact;
      element.textContent = formatter.format(Math.round(seconds / divisor), unit);
    });
  }

  function initializeAutoRefresh() {
    var input = document.querySelector("[data-auto-refresh]");
    if (!input) return;

    try {
      input.checked = window.localStorage.getItem(AUTO_REFRESH_KEY) === "true";
    } catch (_error) {
      input.checked = false;
    }
    input.title = "Refresh this page every 15 seconds";
    input.addEventListener("change", function () {
      try {
        window.localStorage.setItem(AUTO_REFRESH_KEY, input.checked ? "true" : "false");
      } catch (_error) {
        return;
      }
    });

    window.setInterval(function () {
      if (input.checked && document.visibilityState === "visible") window.location.reload();
    }, AUTO_REFRESH_INTERVAL);
  }

  function initializeRetentionCount() {
    var select = document.querySelector("[data-retention-filter]");
    var count = document.querySelector("[data-retention-count]");
    if (!select || !count) return;

    var update = function () {
      if (!select.value) {
        count.hidden = true;
        return;
      }

      var option = select.options[select.selectedIndex];
      var records = Number(option.dataset.count || "0");
      count.textContent = records + (records === 1 ? " record" : " records");
      count.hidden = false;
    };

    select.addEventListener("change", update);
    update();
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-copy-target]");
    if (button) copyText(button);
  });

  document.addEventListener("keydown", function (event) {
    if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return;
    if (/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName)) return;

    var search = document.querySelector("[data-search]");
    if (!search) return;
    event.preventDefault();
    search.focus();
  });

  document.addEventListener("DOMContentLoaded", function () {
    formatRelativeTimes();
    initializeAutoRefresh();
    initializeRetentionCount();
  });
})();
