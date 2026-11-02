"use strict";
// Draws what the native controller sends and reports what the user does.
// Page titles and favicons are untrusted, so tabs are built with textContent.
(() => {
  const post = message => window.webkit.messageHandlers.apsaChrome.postMessage(message);
  const $ = selector => document.querySelector(selector);
  const address = $("#address");
  const reader = $("#reader");
  const tabsRoot = $("#tabs");
  const tabRows = new Map();
  const star = $("#star");
  const shield = $("#shield");
  const translate = $("#translate");
  const addressTools = $("#addressTools");
  const addressToolsToggle = $("#addressToolsToggle");
  const bookmarksRoot = $("#bookmarks");
  const bookmarkList = $("#bookmarkList");
  const bookmarksToggle = $("#bookmarksToggle");
  let drawnBookmarks = "";
  const root = document.documentElement;
  let state = null;
  let announced = false;
  let edited = false;
  let strings = {};
  const t = text => strings[text] ?? text;

  const editing = () => document.activeElement === address && document.hasFocus();

  function sendRegions() {
    const elements = [...document.querySelectorAll(".toolbar button, .toolbar .address")];
    if (!document.body.classList.contains("sidebar-hidden")) elements.push($(".sidebar"));
    const rects = elements.map(element => element.getBoundingClientRect())
      .filter(rect => rect.width > 0 && rect.height > 0)
      .slice(0, 64)
      .map(rect => [rect.x, rect.y, rect.width, rect.height]);
    post({ event: "regions", rects });
  }

  let regionsPending = false;
  function scheduleRegions() {
    if (regionsPending) return;
    regionsPending = true;
    requestAnimationFrame(() => { regionsPending = false; sendRegions(); });
  }

  function makeRow(tab) {
    const row = document.createElement("div");
    row.className = "tab";
    const select = document.createElement("button");
    select.className = "tab-select";
    select.setAttribute("role", "radio");
    select.addEventListener("click", () => post({ command: "selectTab", id: row.dataset.id }));
    const icon = document.createElement("span");
    icon.className = "tab-icon";
    const favicon = document.createElement("img");
    favicon.className = "tab-favicon";
    favicon.alt = "";
    const title = document.createElement("span");
    title.className = "tab-title";
    const detail = document.createElement("span");
    detail.className = "tab-detail";
    const close = document.createElement("button");
    close.className = "icon i-close tab-close";
    close.title = t("Close Tab");
    close.setAttribute("aria-label", close.title);
    close.addEventListener("click", () => post({ command: "closeTab", id: row.dataset.id }));
    row.dataset.id = tab.id;
    row.append(select, icon, favicon, title, detail, close);
    row.parts = { select, icon, favicon, title, detail };
    return row;
  }

  function makeFolderRow(folder) {
    const row = document.createElement("button");
    row.className = "tab-folder";
    row.dataset.id = folder.id;
    const chevron = document.createElement("span");
    chevron.className = "tab-folder-chevron";
    const name = document.createElement("span");
    name.className = "tab-folder-name";
    const count = document.createElement("span");
    count.className = "tab-folder-count";
    row.append(chevron, name, count);
    row.parts = { chevron, name, count };
    row.addEventListener("click", () => post({ command: "toggleFolder", id: row.dataset.id }));
    row.addEventListener("contextmenu", event => {
      event.preventDefault();
      post({ command: "folderMenu", id: row.dataset.id });
    });
    return row;
  }

  function drawTabs(tabs) {
    const seen = new Set();
    tabs.forEach((tab, index) => {
      seen.add(tab.id);
      let row = tabRows.get(tab.id);
      if (tab.kind === "folder") {
        if (!row) { row = makeFolderRow(tab); tabRows.set(tab.id, row); }
        const { chevron, name, count } = row.parts;
        chevron.className = `tab-folder-chevron ${tab.collapsed ? "i-section-closed" : "i-section-open"}`;
        name.textContent = tab.name;
        count.textContent = String(tab.count);
        row.setAttribute("aria-expanded", String(!tab.collapsed));
        row.setAttribute("aria-label", tab.name);
        if (tabsRoot.children[index] !== row) tabsRoot.insertBefore(row, tabsRoot.children[index] || null);
        return;
      }
      if (!row) {
        row = makeRow(tab);
        tabRows.set(tab.id, row);
        row.addEventListener("contextmenu", event => {
          event.preventDefault();
          post({ command: "tabMenu", id: row.dataset.id });
        });
      }
      row.classList.toggle("is-nested", Boolean(tab.nested));
      const { select, icon, favicon, title, detail } = row.parts;
      row.classList.toggle("is-active", tab.active);
      select.setAttribute("aria-checked", String(tab.active));
      select.setAttribute("aria-label", tab.title);
      title.textContent = tab.title;
      detail.textContent = tab.detail;
      icon.className = `tab-icon i-tab-${tab.symbol}`;
      icon.hidden = Boolean(tab.icon);
      favicon.hidden = !tab.icon;
      if (tab.icon && favicon.getAttribute("src") !== tab.icon) favicon.src = tab.icon;
      if (tabsRoot.children[index] !== row) tabsRoot.insertBefore(row, tabsRoot.children[index] || null);
    });
    for (const [id, row] of tabRows) {
      if (!seen.has(id)) { row.remove(); tabRows.delete(id); }
    }
  }

  function makeBookmarkRow(bookmark) {
    const row = document.createElement("button");
    row.className = "bookmark";
    row.title = bookmark.url;
    row.setAttribute("aria-label", bookmark.title);
    if (bookmark.icon) {
      const favicon = document.createElement("img");
      favicon.className = "bookmark-favicon";
      favicon.alt = "";
      favicon.src = bookmark.icon;
      row.append(favicon);
    } else {
      const icon = document.createElement("span");
      icon.className = "bookmark-icon i-bookmark-web";
      row.append(icon);
    }
    const title = document.createElement("span");
    title.className = "bookmark-title";
    title.textContent = bookmark.title;
    row.append(title);
    row.addEventListener("click", () => post({ command: "openBookmark", id: bookmark.id }));
    row.addEventListener("contextmenu", event => {
      event.preventDefault();
      post({ command: "bookmarkMenu", id: bookmark.id });
    });
    return row;
  }

  function drawBookmarks(bookmarks, collapsed) {
    bookmarksRoot.hidden = bookmarks.length === 0;
    bookmarksRoot.classList.toggle("is-collapsed", collapsed);
    bookmarksToggle.className = `icon ${collapsed ? "i-section-closed" : "i-section-open"}`;
    const key = JSON.stringify(bookmarks);
    if (key === drawnBookmarks) return;
    drawnBookmarks = key;
    let folder = null;
    const nodes = [];
    for (const bookmark of bookmarks) {
      if (bookmark.folder && bookmark.folder !== folder) {
        const label = document.createElement("div");
        label.className = "bookmark-folder";
        label.textContent = bookmark.folder;
        nodes.push(label);
      }
      folder = bookmark.folder || null;
      nodes.push(makeBookmarkRow(bookmark));
    }
    bookmarkList.replaceChildren(...nodes);
  }

  function drawTheme(theme) {
    root.dataset.theme = theme.name;
    root.dataset.appearance = theme.light ? "light" : "dark";
    for (const [name, value] of Object.entries(theme.tokens)) root.style.setProperty(`--${name}`, value);
  }

  window.apsaChrome = {
    // The page is written in English; another language arrives before the first paint.
    setStrings(language, table) {
      strings = table;
      root.lang = language;
      for (const element of document.querySelectorAll("[title], [aria-label], [placeholder]")) {
        for (const name of ["title", "aria-label", "placeholder"]) {
          if (element.hasAttribute(name)) element.setAttribute(name, t(element.getAttribute(name)));
        }
      }
      for (const title of document.querySelectorAll(".sidebar-title")) title.textContent = t(title.textContent);
    },
    setStyles(symbols, stylesheet) {
      $("#symbols").textContent = symbols;
      $("#stylesheet").textContent = stylesheet;
      scheduleRegions();
    },
    update(next) {
      state = next;
      drawTheme(next.theme);
      root.style.setProperty("--titlebar-offset", `${next.titlebarOffset}px`);
      root.style.setProperty("--chrome-inset", `${next.inset}px`);
      document.body.classList.toggle("sidebar-hidden", !next.sidebarVisible);
      document.body.classList.toggle("toolbar-hidden", !next.toolbarVisible);
      for (const button of document.querySelectorAll("[data-state]")) button.disabled = !next.enabled[button.dataset.state];
      reader.disabled = !next.reader.enabled;
      reader.title = next.reader.tip;
      reader.setAttribute("aria-label", next.reader.tip);
      reader.setAttribute("aria-pressed", String(next.reader.on));
      reader.className = `icon ${next.reader.on ? "i-reader-on" : "i-reader"}`;
      if (address.placeholder !== next.placeholder) address.placeholder = next.placeholder;
      if (!editing()) address.value = next.address;
      addressTools.classList.toggle("is-collapsed", !next.addressTools.expanded);
      addressToolsToggle.className = `icon ${next.addressTools.expanded ? "i-tools-close" : "i-tools-open"}`;
      addressToolsToggle.title = next.addressTools.tip;
      addressToolsToggle.setAttribute("aria-label", next.addressTools.tip);
      addressToolsToggle.setAttribute("aria-expanded", String(next.addressTools.expanded));
      translate.hidden = !next.translation.available;
      translate.disabled = !next.translation.enabled;
      translate.title = next.translation.tip;
      translate.setAttribute("aria-label", next.translation.tip);
      translate.setAttribute("aria-pressed", String(next.translation.on));
      translate.classList.toggle("is-on", next.translation.on);
      shield.disabled = !next.shield.enabled;
      shield.title = next.shield.tip;
      shield.setAttribute("aria-label", next.shield.tip);
      shield.setAttribute("aria-pressed", String(next.shield.on));
      shield.className = `icon ${next.shield.on ? "i-shield" : "i-shield-off"}`;
      star.disabled = !next.star.enabled;
      star.title = t(next.star.on ? "Remove Bookmark" : "Add Bookmark");
      star.setAttribute("aria-label", star.title);
      star.setAttribute("aria-pressed", String(next.star.on));
      star.className = `icon ${next.star.on ? "i-star-on" : "i-star"}`;
      drawBookmarks(next.bookmarks, next.bookmarksCollapsed);
      drawTabs(next.tabs);
      scheduleRegions();
      if (!announced) {
        announced = true;
        // Two frames: the first paint with the real stylesheet is on screen.
        requestAnimationFrame(() => requestAnimationFrame(() => post({ event: "ready" })));
      }
    },
    focusAddress() { address.focus(); address.select(); }
  };

  document.addEventListener("click", event => {
    const button = event.target.closest("[data-command]");
    if (button && !button.disabled) post({ command: button.dataset.command });
  });
  $(".address").addEventListener("submit", event => {
    event.preventDefault();
    const value = edited || !state ? address.value : state.url;
    address.blur();
    post({ command: "address", value });
  });
  // As in the native field: the short address stays selected until the first
  // edit, and typing replaces it. Moving the caret switches to the full URL.
  const startCaretEdit = () => {
    if (edited || !state) return;
    edited = true;
    address.value = state.url;
  };
  address.addEventListener("focus", () => { edited = false; address.select(); });
  address.addEventListener("beforeinput", () => { edited = true; });
  address.addEventListener("mousedown", event => {
    if (edited && document.hasFocus()) return;
    event.preventDefault();
    address.focus();
    address.select();
  });
  address.addEventListener("keydown", event => {
    if (event.key === "Escape" && state) {
      edited = false;
      address.value = state.address;
      address.select();
    } else if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) {
      startCaretEdit();
    }
  });
  // The page took keyboard focus: let the next focus start a fresh edit.
  window.addEventListener("blur", () => address.blur());
  document.addEventListener("contextmenu", event => {
    if (event.target !== address) event.preventDefault();
  });
  document.addEventListener("dragstart", event => event.preventDefault());
  new ResizeObserver(scheduleRegions).observe(root);
  addressTools.addEventListener("transitionend", scheduleRegions);
})();
