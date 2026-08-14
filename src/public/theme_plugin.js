(function () {
  "use strict";

  var STORAGE_KEY = "restgate.theme.v1";
  var UI_STYLE_ID = "local-theme-plugin-style";
  var THEME_STYLE_ID = "local-theme-runtime-style";
  var ROOT_ID = "local-theme-plugin-root";

  var DEFAULT_CONFIG = {
    enabled: false,
    brightness: 100,
    contrast: 100,
    sepia: 0,
    grayscale: 0
  };

  var CONTROL_DEFS = [
    {key: "brightness", label: "Brightness", min: 50, max: 150, step: 1, defaultValue: 100},
    {key: "contrast", label: "Contrast", min: 50, max: 150, step: 1, defaultValue: 100},
    {key: "sepia", label: "Sepia", min: 0, max: 100, step: 1, defaultValue: 0},
    {key: "grayscale", label: "Grayscale", min: 0, max: 100, step: 1, defaultValue: 0}
  ];

  var DARK_PALETTE = {
    bg: "#101720",
    panel: "#17212b",
    panelSoft: "#1d2834",
    line: "#344052",
    lineStrong: "#536174",
    focus: "#8ab4f8",
    text: "#e6edf4",
    muted: "#9aa7b8",
    accent: "#8ab4f8",
    accentSoft: "#172b46",
    ok: "#81c995",
    okSoft: "#17351f",
    warn: "#fdd663",
    warnSoft: "#3a2d10",
    danger: "#f28b82",
    dangerSoft: "#3d1f22",
    tableRowHover: "#1d2a38",
    control: "#202b38",
    controlHover: "#263447",
    meterTrack: "#2c3848",
    shadow: "#000000"
  };

  var config = normalizeConfig(readConfig());
  var controls = {};
  var elements = {};

  function init() {
    if (document.getElementById(ROOT_ID)) {
      applyTheme();
      return;
    }

    injectUIStyle();
    mountUI();
    applyTheme();
    updateUI();
  }

  function readConfig() {
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      return raw ? JSON.parse(raw) : {};
    } catch (_error) {
      return {};
    }
  }

  function writeConfig() {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
    } catch (_error) {
      return;
    }
  }

  function normalizeConfig(value) {
    var source = value && typeof value === "object" ? value : {};
    return {
      enabled: Boolean(source.enabled),
      brightness: normalizeNumber(source.brightness, 50, 150, DEFAULT_CONFIG.brightness),
      contrast: normalizeNumber(source.contrast, 50, 150, DEFAULT_CONFIG.contrast),
      sepia: normalizeNumber(source.sepia, 0, 100, DEFAULT_CONFIG.sepia),
      grayscale: normalizeNumber(source.grayscale, 0, 100, DEFAULT_CONFIG.grayscale)
    };
  }

  function normalizeNumber(value, min, max, fallback) {
    var number = Number(value);
    if (!Number.isFinite(number)) {
      return fallback;
    }
    return Math.max(min, Math.min(max, Math.round(number)));
  }

  function setConfig(nextConfig) {
    config = normalizeConfig(Object.assign({}, config, nextConfig));
    writeConfig();
    applyTheme();
    updateUI();
  }

  function mountUI() {
    var mount = document.getElementById("local-theme-plugin");
    if (!mount) {
      mount = document.querySelector(".header-main");
    }
    if (!mount) {
      return;
    }

    var root = document.createElement("div");
    root.id = ROOT_ID;
    root.className = "ltp";

    var toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = "ltp-toggle";
    toggle.setAttribute("aria-pressed", "false");
    toggle.innerHTML = '<span class="ltp-toggle__label">Theme</span><span class="ltp-toggle__state">Off</span>';
    toggle.addEventListener("click", function () {
      setConfig({enabled: !config.enabled});
    });

    var settings = document.createElement("button");
    settings.type = "button";
    settings.className = "ltp-settings";
    settings.textContent = "Settings";
    settings.setAttribute("aria-haspopup", "dialog");
    settings.setAttribute("aria-expanded", "false");
    settings.addEventListener("click", function (event) {
      event.stopPropagation();
      setPanelOpen(elements.panel.hidden);
    });

    var panel = createPanel();

    root.appendChild(toggle);
    root.appendChild(settings);
    root.appendChild(panel);
    mount.appendChild(root);

    elements.root = root;
    elements.toggle = toggle;
    elements.toggleState = toggle.querySelector(".ltp-toggle__state");
    elements.settings = settings;
    elements.panel = panel;

    document.addEventListener("click", function (event) {
      if (!elements.root || elements.root.contains(event.target)) {
        return;
      }
      setPanelOpen(false);
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        setPanelOpen(false);
      }
    });
  }

  function createPanel() {
    var panel = document.createElement("div");
    panel.className = "ltp-panel";
    panel.hidden = true;
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-modal", "false");
    panel.setAttribute("aria-labelledby", "ltp-title");
    panel.addEventListener("click", function (event) {
      event.stopPropagation();
    });

    var header = document.createElement("div");
    header.className = "ltp-panel__header";

    var title = document.createElement("h2");
    title.id = "ltp-title";
    title.textContent = "Theme settings";

    var close = document.createElement("button");
    close.type = "button";
    close.className = "ltp-close";
    close.setAttribute("aria-label", "Close theme settings");
    close.textContent = "x";
    close.addEventListener("click", function () {
      setPanelOpen(false);
    });

    header.appendChild(title);
    header.appendChild(close);
    panel.appendChild(header);

    var enabledRow = document.createElement("label");
    enabledRow.className = "ltp-check";

    var enabledInput = document.createElement("input");
    enabledInput.type = "checkbox";
    enabledInput.addEventListener("change", function () {
      setConfig({enabled: enabledInput.checked});
    });

    var enabledText = document.createElement("span");
    enabledText.textContent = "Dark theme";

    enabledRow.appendChild(enabledInput);
    enabledRow.appendChild(enabledText);
    panel.appendChild(enabledRow);
    elements.enabledInput = enabledInput;

    CONTROL_DEFS.forEach(function (definition) {
      panel.appendChild(createControl(definition));
    });

    var actions = document.createElement("div");
    actions.className = "ltp-actions";

    var reset = document.createElement("button");
    reset.type = "button";
    reset.className = "subtle compact";
    reset.textContent = "Reset";
    reset.addEventListener("click", function () {
      setConfig({
        brightness: DEFAULT_CONFIG.brightness,
        contrast: DEFAULT_CONFIG.contrast,
        sepia: DEFAULT_CONFIG.sepia,
        grayscale: DEFAULT_CONFIG.grayscale
      });
    });

    var done = document.createElement("button");
    done.type = "button";
    done.className = "compact";
    done.textContent = "Close";
    done.addEventListener("click", function () {
      setPanelOpen(false);
    });

    actions.appendChild(reset);
    actions.appendChild(done);
    panel.appendChild(actions);

    return panel;
  }

  function createControl(definition) {
    var row = document.createElement("div");
    row.className = "ltp-control";

    var label = document.createElement("label");
    label.className = "ltp-control__label";
    label.setAttribute("for", "ltp-" + definition.key);

    var labelText = document.createElement("span");
    labelText.textContent = definition.label;

    var valueText = document.createElement("span");
    valueText.className = "ltp-control__value";

    label.appendChild(labelText);
    label.appendChild(valueText);

    var input = document.createElement("input");
    input.id = "ltp-" + definition.key;
    input.type = "range";
    input.min = String(definition.min);
    input.max = String(definition.max);
    input.step = String(definition.step);
    input.addEventListener("input", function () {
      var next = {};
      next[definition.key] = Number(input.value);
      updateRangeProgress(input, definition);
      setConfig(next);
    });

    row.appendChild(label);
    row.appendChild(input);
    controls[definition.key] = {input: input, valueText: valueText, definition: definition};
    return row;
  }

  function setPanelOpen(open) {
    if (!elements.panel) {
      return;
    }

    elements.panel.hidden = !open;
    elements.settings.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) {
      var firstInput = elements.panel.querySelector("input, button");
      if (firstInput) {
        firstInput.focus();
      }
    }
  }

  function updateUI() {
    if (!elements.toggle) {
      return;
    }

    elements.toggle.dataset.enabled = config.enabled ? "true" : "false";
    elements.toggle.setAttribute("aria-pressed", config.enabled ? "true" : "false");
    elements.toggleState.textContent = config.enabled ? "On" : "Off";

    if (elements.enabledInput) {
      elements.enabledInput.checked = config.enabled;
    }

    CONTROL_DEFS.forEach(function (definition) {
      var control = controls[definition.key];
      if (!control) {
        return;
      }
      control.input.value = String(config[definition.key]);
      updateRangeProgress(control.input, definition);
      control.valueText.textContent = formatOffset(config[definition.key], definition.defaultValue);
    });
  }

  function updateRangeProgress(input, definition) {
    var min = Number(definition.min);
    var max = Number(definition.max);
    var value = Number(input.value);
    var progress = ((value - min) / (max - min)) * 100;
    input.style.setProperty("--ltp-range-progress", Math.max(0, Math.min(100, progress)) + "%");
  }

  function formatOffset(value, defaultValue) {
    if (value === defaultValue) {
      return "off";
    }
    return value > defaultValue ? "+" + (value - defaultValue) : "-" + (defaultValue - value);
  }

  function applyTheme() {
    var root = document.documentElement;
    root.classList.toggle("local-theme-enabled", config.enabled);

    var style = document.getElementById(THEME_STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = THEME_STYLE_ID;
      document.head.appendChild(style);
    }

    style.textContent = config.enabled ? buildThemeCSS(config) : "";
  }

  function buildThemeCSS(themeConfig) {
    var matrix = createFilterMatrix({
      brightness: themeConfig.brightness,
      contrast: themeConfig.contrast,
      sepia: themeConfig.sepia,
      grayscale: themeConfig.grayscale,
      mode: 0
    });

    var colors = {};
    Object.keys(DARK_PALETTE).forEach(function (key) {
      colors[key] = filterHexColor(DARK_PALETTE[key], matrix);
    });
    colors.accentContrast = readableTextColor(colors.accent, colors.bg, colors.text);

    return [
      ":root.local-theme-enabled {",
      "  --bg: " + colors.bg + ";",
      "  --panel: " + colors.panel + ";",
      "  --panel-soft: " + colors.panelSoft + ";",
      "  --line: " + colors.line + ";",
      "  --line-strong: " + colors.lineStrong + ";",
      "  --focus: " + colors.focus + ";",
      "  --text: " + colors.text + ";",
      "  --muted: " + colors.muted + ";",
      "  --accent: " + colors.accent + ";",
      "  --accent-contrast: " + colors.accentContrast + ";",
      "  --accent-soft: " + colors.accentSoft + ";",
      "  --ok: " + colors.ok + ";",
      "  --ok-soft: " + colors.okSoft + ";",
      "  --warn: " + colors.warn + ";",
      "  --warn-soft: " + colors.warnSoft + ";",
      "  --danger: " + colors.danger + ";",
      "  --danger-soft: " + colors.dangerSoft + ";",
      "  --table-row-hover: " + colors.tableRowHover + ";",
      "  color-scheme: dark;",
      "}",
      "html.local-theme-enabled, html.local-theme-enabled body {",
      "  background: var(--bg);",
      "  color: var(--text);",
      "}",
      "html.local-theme-enabled .brand-name,",
      "html.local-theme-enabled .nav a,",
      "html.local-theme-enabled .metric-value,",
      "html.local-theme-enabled .kv-value {",
      "  color: var(--text);",
      "}",
      "html.local-theme-enabled .nav a.active,",
      "html.local-theme-enabled .nav a.active:hover {",
      "  border-color: var(--accent);",
      "  background: var(--accent);",
      "  color: var(--accent-contrast);",
      "  text-decoration: none;",
      "}",
      "html.local-theme-enabled input[type=\"text\"],",
      "html.local-theme-enabled input[type=\"password\"],",
      "html.local-theme-enabled input[type=\"file\"],",
      "html.local-theme-enabled select,",
      "html.local-theme-enabled textarea {",
      "  background: " + colors.control + ";",
      "  color: var(--text);",
      "  border-color: var(--line-strong);",
      "}",
      "html.local-theme-enabled button,",
      "html.local-theme-enabled .button {",
      "  background: " + colors.control + ";",
      "  color: var(--text);",
      "  border-color: var(--line-strong);",
      "  box-shadow: none;",
      "}",
      "html.local-theme-enabled button:hover,",
      "html.local-theme-enabled .button:hover {",
      "  background: " + colors.controlHover + ";",
      "  color: var(--accent);",
      "}",
      "html.local-theme-enabled button.primary,",
      "html.local-theme-enabled button.primary:hover,",
      "html.local-theme-enabled .button.primary,",
      "html.local-theme-enabled .button.primary:hover {",
      "  border-color: var(--accent);",
      "  background: var(--accent);",
      "  color: var(--accent-contrast);",
      "}",
      "html.local-theme-enabled button.ltp-toggle[data-enabled=\"true\"],",
      "html.local-theme-enabled button.ltp-toggle[data-enabled=\"true\"]:hover {",
      "  border-color: var(--accent);",
      "  background: var(--accent);",
      "  color: var(--accent-contrast);",
      "}",
      "html.local-theme-enabled button.ltp-toggle[data-enabled=\"true\"] .ltp-toggle__state {",
      "  color: currentColor;",
      "}",
      "html.local-theme-enabled .code-block,",
      "html.local-theme-enabled .metric {",
      "  background: var(--panel-soft);",
      "}",
      "html.local-theme-enabled .meter {",
      "  background: " + colors.meterTrack + ";",
      "}",
      "html.local-theme-enabled .action-menu-items {",
      "  box-shadow: 0 8px 20px color-mix(in srgb, " + colors.shadow + " 42%, transparent);",
      "}",
      "html.local-theme-enabled ::selection {",
      "  background: var(--accent);",
      "  color: var(--accent-contrast);",
      "}"
    ].join("\n");
  }

  function createFilterMatrix(themeConfig) {
    var matrix = Matrix.identity();
    if (themeConfig.sepia !== 0) {
      matrix = multiplyMatrices(matrix, Matrix.sepia(themeConfig.sepia / 100));
    }
    if (themeConfig.grayscale !== 0) {
      matrix = multiplyMatrices(matrix, Matrix.grayscale(themeConfig.grayscale / 100));
    }
    if (themeConfig.contrast !== 100) {
      matrix = multiplyMatrices(matrix, Matrix.contrast(themeConfig.contrast / 100));
    }
    if (themeConfig.brightness !== 100) {
      matrix = multiplyMatrices(matrix, Matrix.brightness(themeConfig.brightness / 100));
    }
    if (themeConfig.mode === 1) {
      matrix = multiplyMatrices(matrix, Matrix.invertNHue());
    }
    return matrix;
  }

  function multiplyMatrices(m1, m2) {
    var result = [];
    for (var i = 0; i < m1.length; i += 1) {
      result[i] = [];
      for (var j = 0; j < m2[0].length; j += 1) {
        var sum = 0;
        for (var k = 0; k < m1[0].length; k += 1) {
          sum += m1[i][k] * m2[k][j];
        }
        result[i][j] = sum;
      }
    }
    return result;
  }

  function filterHexColor(hexColor, matrix) {
    var rgb = hexToRgb(hexColor);
    var result = applyColorMatrix([rgb.r, rgb.g, rgb.b], matrix);
    return rgbToHex(result[0], result[1], result[2]);
  }

  function applyColorMatrix(rgb, matrix) {
    var source = [[rgb[0] / 255], [rgb[1] / 255], [rgb[2] / 255], [1], [1]];
    var result = multiplyMatrices(matrix, source);
    return [0, 1, 2].map(function (index) {
      return Math.max(0, Math.min(255, Math.round(result[index][0] * 255)));
    });
  }

  function hexToRgb(hexColor) {
    var value = hexColor.replace("#", "");
    if (value.length === 3) {
      value = value.split("").map(function (char) {
        return char + char;
      }).join("");
    }
    return {
      r: parseInt(value.slice(0, 2), 16),
      g: parseInt(value.slice(2, 4), 16),
      b: parseInt(value.slice(4, 6), 16)
    };
  }

  function rgbToHex(r, g, b) {
    return "#" + [r, g, b].map(function (value) {
      return value.toString(16).padStart(2, "0");
    }).join("");
  }

  function readableTextColor(backgroundHex, darkHex, lightHex) {
    return contrastRatio(backgroundHex, darkHex) >= contrastRatio(backgroundHex, lightHex) ? darkHex : lightHex;
  }

  function contrastRatio(firstHex, secondHex) {
    var first = relativeLuminance(hexToRgb(firstHex));
    var second = relativeLuminance(hexToRgb(secondHex));
    var lighter = Math.max(first, second);
    var darker = Math.min(first, second);
    return (lighter + 0.05) / (darker + 0.05);
  }

  function relativeLuminance(rgb) {
    var channels = [rgb.r, rgb.g, rgb.b].map(function (value) {
      var normalized = value / 255;
      if (normalized <= 0.03928) {
        return normalized / 12.92;
      }
      return Math.pow((normalized + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
  }

  var Matrix = {
    identity: function () {
      return [
        [1, 0, 0, 0, 0],
        [0, 1, 0, 0, 0],
        [0, 0, 1, 0, 0],
        [0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1]
      ];
    },

    invertNHue: function () {
      return [
        [0.333, -0.667, -0.667, 0, 1],
        [-0.667, 0.333, -0.667, 0, 1],
        [-0.667, -0.667, 0.333, 0, 1],
        [0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1]
      ];
    },

    brightness: function (value) {
      return [
        [value, 0, 0, 0, 0],
        [0, value, 0, 0, 0],
        [0, 0, value, 0, 0],
        [0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1]
      ];
    },

    contrast: function (value) {
      var t = (1 - value) / 2;
      return [
        [value, 0, 0, 0, t],
        [0, value, 0, 0, t],
        [0, 0, value, 0, t],
        [0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1]
      ];
    },

    sepia: function (value) {
      return [
        [0.393 + 0.607 * (1 - value), 0.769 - 0.769 * (1 - value), 0.189 - 0.189 * (1 - value), 0, 0],
        [0.349 - 0.349 * (1 - value), 0.686 + 0.314 * (1 - value), 0.168 - 0.168 * (1 - value), 0, 0],
        [0.272 - 0.272 * (1 - value), 0.534 - 0.534 * (1 - value), 0.131 + 0.869 * (1 - value), 0, 0],
        [0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1]
      ];
    },

    grayscale: function (value) {
      return [
        [0.2126 + 0.7874 * (1 - value), 0.7152 - 0.7152 * (1 - value), 0.0722 - 0.0722 * (1 - value), 0, 0],
        [0.2126 - 0.2126 * (1 - value), 0.7152 + 0.2848 * (1 - value), 0.0722 - 0.0722 * (1 - value), 0, 0],
        [0.2126 - 0.2126 * (1 - value), 0.7152 - 0.7152 * (1 - value), 0.0722 + 0.9278 * (1 - value), 0, 0],
        [0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1]
      ];
    }
  };

  function injectUIStyle() {
    if (document.getElementById(UI_STYLE_ID)) {
      return;
    }

    var style = document.createElement("style");
    style.id = UI_STYLE_ID;
    style.textContent = [
      ".theme-plugin-mount {",
      "  margin-left: auto;",
      "}",
      ".ltp {",
      "  position: relative;",
      "  display: flex;",
      "  align-items: center;",
      "  justify-content: flex-end;",
      "  gap: 6px;",
      "}",
      ".ltp button {",
      "  min-height: 28px;",
      "}",
      ".ltp-toggle {",
      "  gap: 6px;",
      "}",
      ".ltp-toggle__state {",
      "  min-width: 24px;",
      "  color: var(--muted);",
      "  font-size: 11px;",
      "  font-weight: 600;",
      "  text-transform: uppercase;",
      "}",
      ".ltp-toggle[data-enabled=\"true\"],",
      ".ltp-toggle[data-enabled=\"true\"]:hover {",
      "  border-color: var(--accent);",
      "  background: var(--accent);",
      "  color: var(--accent-contrast);",
      "}",
      ".ltp-toggle[data-enabled=\"true\"] .ltp-toggle__state {",
      "  color: currentColor;",
      "}",
      ".ltp-panel {",
      "  box-sizing: border-box;",
      "  position: absolute;",
      "  top: calc(100% + 8px);",
      "  right: 0;",
      "  z-index: 50;",
      "  display: grid;",
      "  gap: var(--space-3);",
      "  width: min(340px, calc(100vw - 32px));",
      "  padding: var(--space-3);",
      "  border: 1px solid var(--line-strong);",
      "  border-radius: var(--radius-2);",
      "  background: var(--panel);",
      "  box-shadow: 0 12px 28px rgba(15, 23, 42, 0.18);",
      "}",
      ".ltp-panel[hidden] {",
      "  display: none;",
      "}",
      ".ltp-panel__header {",
      "  display: flex;",
      "  align-items: center;",
      "  justify-content: space-between;",
      "  gap: var(--space-2);",
      "}",
      ".ltp-panel__header h2 {",
      "  font-size: var(--font-title);",
      "}",
      ".ltp-close {",
      "  width: 28px;",
      "  padding: 0;",
      "}",
      ".ltp-check {",
      "  display: flex;",
      "  align-items: center;",
      "  gap: var(--space-2);",
      "  margin: 0;",
      "  color: var(--text);",
      "  font-size: 13px;",
      "  font-weight: 500;",
      "}",
      ".ltp-check input {",
      "  margin: 0;",
      "}",
      ".ltp-control {",
      "  display: grid;",
      "  gap: 5px;",
      "}",
      ".ltp-control__label {",
      "  display: flex;",
      "  justify-content: space-between;",
      "  gap: var(--space-2);",
      "  margin: 0;",
      "}",
      ".ltp-control__value {",
      "  color: var(--accent);",
      "  font-variant-numeric: tabular-nums;",
      "}",
      ".ltp-control input[type=\"range\"] {",
      "  --ltp-range-progress: 50%;",
      "  appearance: none;",
      "  width: 100%;",
      "  height: 18px;",
      "  margin: 0;",
      "  background: transparent;",
      "  cursor: pointer;",
      "}",
      ".ltp-control input[type=\"range\"]:focus-visible {",
      "  outline: 2px solid var(--focus);",
      "  outline-offset: 2px;",
      "}",
      ".ltp-control input[type=\"range\"]::-webkit-slider-runnable-track {",
      "  height: 5px;",
      "  border-radius: 999px;",
      "  background: linear-gradient(to right, var(--accent) 0 var(--ltp-range-progress), var(--line-strong) var(--ltp-range-progress) 100%);",
      "}",
      ".ltp-control input[type=\"range\"]::-webkit-slider-thumb {",
      "  -webkit-appearance: none;",
      "  appearance: none;",
      "  width: 14px;",
      "  height: 14px;",
      "  margin-top: -4.5px;",
      "  border: 2px solid var(--panel);",
      "  border-radius: 999px;",
      "  background: var(--accent);",
      "  box-shadow: 0 0 0 1px var(--line-strong);",
      "}",
      ".ltp-control input[type=\"range\"]::-moz-range-track {",
      "  height: 5px;",
      "  border: 0;",
      "  border-radius: 999px;",
      "  background: var(--line-strong);",
      "}",
      ".ltp-control input[type=\"range\"]::-moz-range-progress {",
      "  height: 5px;",
      "  border-radius: 999px;",
      "  background: var(--accent);",
      "}",
      ".ltp-control input[type=\"range\"]::-moz-range-thumb {",
      "  width: 14px;",
      "  height: 14px;",
      "  border: 2px solid var(--panel);",
      "  border-radius: 999px;",
      "  background: var(--accent);",
      "  box-shadow: 0 0 0 1px var(--line-strong);",
      "}",
      ".ltp-actions {",
      "  display: flex;",
      "  justify-content: flex-end;",
      "  gap: var(--space-2);",
      "}",
      "@media (max-width: 860px) {",
      "  .theme-plugin-mount {",
      "    margin: var(--space-2) 0 0;",
      "  }",
      "  .ltp {",
      "    justify-content: flex-start;",
      "  }",
      "}",
      "@media (max-width: 520px) {",
      "  .ltp-panel {",
      "    top: calc(100% + 8px);",
      "    right: 0;",
      "    left: 0;",
      "    width: auto;",
      "  }",
      "}"
    ].join("\n");
    document.head.appendChild(style);
  }

  window.LocalThemePlugin = {
    init: init,
    getConfig: function () {
      return Object.assign({}, config);
    },
    setConfig: setConfig
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
