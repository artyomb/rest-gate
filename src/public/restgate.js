(function () {
  "use strict";

  var AUTO_REFRESH_KEY = "restgate.logs.autoRefresh.v1";
  var AUTO_APPLY_KEY = "restgate.logs.autoApply.v1";
  var AUTO_REFRESH_INTERVAL = 15000;
  var AUTO_APPLY_DELAY = 450;

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

  function initializeAutoApply() {
    var form = document.querySelector("[data-filter-form]");
    var input = document.querySelector("[data-auto-apply]");
    if (!form || !input) return;

    var search = form.querySelector("[data-search]");
    var timer;
    var submit = function () {
      window.clearTimeout(timer);
      if (typeof form.requestSubmit === "function") {
        form.requestSubmit();
      } else {
        form.submit();
      }
    };

    try {
      input.checked = window.localStorage.getItem(AUTO_APPLY_KEY) === "true";
    } catch (_error) {
      input.checked = false;
    }

    input.addEventListener("change", function () {
      try {
        window.localStorage.setItem(AUTO_APPLY_KEY, input.checked ? "true" : "false");
      } catch (_error) {
        // The control remains useful for this page when storage is unavailable.
      }
      if (input.checked) submit();
    });

    form.addEventListener("change", function (event) {
      if (!input.checked || event.target === input || event.target === search) return;
      submit();
    });

    if (search) {
      search.addEventListener("input", function () {
        if (!input.checked) return;
        window.clearTimeout(timer);
        timer = window.setTimeout(submit, AUTO_APPLY_DELAY);
      });
    }

    form.addEventListener("submit", function () {
      window.clearTimeout(timer);
    });
  }

  function deleteRecord(button) {
    var label = button.dataset.deleteLabel || "this record";
    var attachment = button.dataset.deleteAttachment === "true";
    var files = attachment ? "the JSON record and its binary attachment" : "the JSON record";
    var confirmed = window.confirm(
      "Delete stored record?\n\n" + label + "\n\nThis permanently removes " + files + ". This cannot be undone."
    );
    if (!confirmed) return;

    var original = button.textContent;
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
    button.textContent = "Deleting…";

    window.fetch(button.dataset.deleteUrl, {
      method: "DELETE",
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        "X-Restgate-Action": "delete-record"
      }
    }).then(function (response) {
      if (response.ok || response.status === 404) return;
      return response.text().then(function (message) {
        throw new Error(message || "The record could not be deleted.");
      });
    }).then(function () {
      window.location.assign(button.dataset.deleteReturn || "/_restgate");
    }).catch(function (error) {
      button.disabled = false;
      button.removeAttribute("aria-busy");
      button.textContent = original;
      window.alert(error.message || "The record could not be deleted.");
    });
  }

  document.addEventListener("click", function (event) {
    var deleteButton = event.target.closest("[data-delete-record]");
    if (deleteButton) {
      deleteRecord(deleteButton);
      return;
    }

    var copyButton = event.target.closest("[data-copy-target]");
    if (copyButton) copyText(copyButton);
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
    initializeAutoApply();
  });
})();
