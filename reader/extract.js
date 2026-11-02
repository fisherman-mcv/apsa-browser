// Splits a rendered page into blocks and describes each one with numbers a model can
// judge: what it is, where it sits, what it looks like and what surrounds it.
// Nothing here decides what is content. Field values and passwords are never read.
(() => {
  const clean = value => String(value || "").replace(/[\s ]+/g, " ").trim();
  const NEGATIVE = /(^|[-_\s])(ad|ads|advert|advertisement|banner|breadcrumbs?|carousel|comments?|cookie|consent|footer|header|masthead|menu|nav|navbar|newsletter|outbrain|popup|promo|recommend|related|share|sharing|sidebar|social|sponsor|subscribe|taboola|toolbar|widget)([-_\s]|$)/i;
  const POSITIVE = /(^|[-_\s])(article|articlebody|article-body|article-content|body-content|content|entry|main|post|post-content|prose|story|text|markdown)([-_\s]|$)/i;
  const TEXT_TAGS = new Set(["P", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "BLOCKQUOTE", "PRE", "DD", "DT", "FIGCAPTION", "TH", "TD", "CAPTION", "SUMMARY", "ADDRESS"]);
  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "OBJECT", "EMBED", "INPUT", "TEXTAREA", "SELECT", "OPTION", "BUTTON", "HEAD", "MATH"]);
  const INLINE = new Set(["A", "ABBR", "B", "BDI", "BDO", "BR", "CITE", "CODE", "DATA", "DEL", "DFN", "EM", "FONT", "I", "IMG", "INS", "KBD", "MARK", "NOBR", "Q", "S", "SAMP", "SMALL", "SPAN", "STRONG", "SUB", "SUP", "TIME", "TT", "U", "VAR", "WBR"]);
  const MAX_BLOCKS = 4000;
  const docWidth = Math.max(1, document.documentElement.clientWidth || innerWidth);
  const docHeight = Math.max(1, document.documentElement.scrollHeight);

  const hasOwnText = element => {
    for (const child of element.childNodes) {
      if (child.nodeType === Node.TEXT_NODE && child.textContent.trim()) return true;
      if (child.nodeType === Node.ELEMENT_NODE && INLINE.has(child.tagName) && clean(child.textContent)) return true;
    }
    return false;
  };
  const hasBlockChild = element => [...element.children].some(child => !INLINE.has(child.tagName) && !SKIP.has(child.tagName.toUpperCase()) && clean(child.textContent));
  const visible = (element, style, rect) => style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity) > 0.05 && rect.width >= 2 && rect.height >= 2;

  // Text of a table stays together: its rows mean nothing apart.
  const blocks = [];
  // A data table has many short cells. Tables used for page layout hold whole
  // paragraphs or other tables, and their cells are read as separate blocks.
  const isDataTable = table => {
    const rows = table.querySelectorAll("tr").length;
    const cells = [...table.querySelectorAll("td,th")];
    if (rows < 2 || cells.length <= rows || table.querySelector("table,p,h1,h2,h3,ul,ol")) return false;
    return cells.every(cell => clean(cell.textContent).length <= 300);
  };
  const collect = element => {
    if (blocks.length >= MAX_BLOCKS || SKIP.has(element.tagName.toUpperCase())) return;
    const style = getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden") return;
    if (element.tagName === "TABLE" && clean(element.textContent).length) {
      const rect = element.getBoundingClientRect();
      if (isDataTable(element)) {
        if (visible(element, style, rect)) blocks.push({ element, style, rect, kind: "table" });
        return;
      }
    }
    if (element.tagName === "PRE" || element.tagName === "BLOCKQUOTE" && !hasBlockChild(element)) {
      const rect = element.getBoundingClientRect();
      if (clean(element.textContent) && visible(element, style, rect)) blocks.push({ element, style, rect, kind: "text" });
      return;
    }
    if (element.tagName === "IMG") {
      const rect = element.getBoundingClientRect();
      if (visible(element, style, rect) && rect.width >= 80 && rect.height >= 60) blocks.push({ element, style, rect, kind: "image" });
      return;
    }
    const leaf = (TEXT_TAGS.has(element.tagName) || hasOwnText(element)) && !hasBlockChild(element);
    if (leaf && clean(element.textContent)) {
      const rect = element.getBoundingClientRect();
      if (visible(element, style, rect)) blocks.push({ element, style, rect, kind: "text" });
      for (const image of element.querySelectorAll("img")) collect(image);
      return;
    }
    for (const child of element.children) collect(child);
  };
  if (document.body) collect(document.body);

  // The page's own reading column: where most of its running text sits.
  const weights = new Map();
  const sizes = new Map();
  for (const block of blocks) {
    if (block.kind === "image") continue;
    block.text = clean(block.element.innerText || block.element.textContent);
    const length = block.text.length;
    const left = Math.round(block.rect.left / 8) * 8;
    if (length >= 60) {
      weights.set(left, (weights.get(left) || 0) + length);
      const size = Math.round(parseFloat(block.style.fontSize) || 16);
      sizes.set(size, (sizes.get(size) || 0) + length);
    }
  }
  const dominant = map => [...map.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
  const columnLeft = dominant(weights) ?? 0;
  const bodySize = dominant(sizes) ?? 16;
  const totalText = blocks.reduce((sum, block) => sum + (block.text?.length || 0), 0) || 1;
  const parentText = new Map();
  for (const block of blocks) {
    const parent = block.element.parentElement;
    if (parent) parentText.set(parent, (parentText.get(parent) || 0) + (block.text?.length || 0));
  }
  const title = clean(document.title).toLowerCase();

  const ancestors = element => {
    const found = { main: 0, article: 0, nav: 0, aside: 0, footer: 0, header: 0, form: 0, dialog: 0, negative: 0, positive: 0, fixed: 0, depth: 0, list: 0 };
    let hops = 0;
    for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
      found.depth += 1;
      const tag = node.tagName;
      const role = node.getAttribute("role") || "";
      if (tag === "MAIN" || role === "main") found.main = 1;
      if (tag === "ARTICLE" || role === "article" || node.hasAttribute("itemprop") && /articleBody/i.test(node.getAttribute("itemprop"))) found.article = 1;
      if (tag === "NAV" || role === "navigation") found.nav = 1;
      if (tag === "ASIDE" || role === "complementary") found.aside = 1;
      if (tag === "FOOTER" || role === "contentinfo") found.footer = 1;
      if (tag === "HEADER" || role === "banner") found.header = 1;
      if (tag === "FORM" || role === "search") found.form = 1;
      if (tag === "DIALOG" || role === "dialog" || role === "alertdialog") found.dialog = 1;
      if (tag === "UL" || tag === "OL" || tag === "DL") found.list = 1;
      if (hops < 8) {
        const marker = `${node.id || ""} ${typeof node.className === "string" ? node.className : ""} ${node.getAttribute("data-testid") || ""}`;
        if (NEGATIVE.test(marker)) found.negative += 1;
        if (POSITIVE.test(marker)) found.positive += 1;
        const position = getComputedStyle(node).position;
        if (position === "fixed" || position === "sticky") found.fixed = 1;
        hops += 1;
      }
    }
    return found;
  };

  const output = blocks.map((block, index) => {
    const { element, style, rect, kind } = block;
    const tag = element.tagName;
    const text = block.text ?? clean(element.getAttribute("alt"));
    const length = text.length;
    const links = kind === "image" ? 0 : [...element.querySelectorAll("a")].reduce((sum, link) => sum + clean(link.textContent).length, element.closest("a") ? length : 0);
    const place = ancestors(element);
    const previous = blocks[index - 1];
    const next = blocks[index + 1];
    const size = parseFloat(style.fontSize) || 16;
    const sentences = (text.match(/[.!?…。！？](\s|$)/g) || []).length;
    const features = {
      isP: +(tag === "P"), isH1: +(tag === "H1"), isH2: +(tag === "H2"), isH3: +/^H[3-6]$/.test(tag), isLi: +(tag === "LI"), isQuote: +(tag === "BLOCKQUOTE"), isPre: +(tag === "PRE"),
      isTable: +(kind === "table"), isImage: +(kind === "image"), isDiv: +(tag === "DIV"), isSpan: +(tag === "SPAN" || tag === "A"), isCaption: +(tag === "FIGCAPTION" || tag === "CAPTION"),
      logLength: Math.log1p(length), words: Math.min(400, text.split(" ").length), sentences: Math.min(40, sentences),
      linkDensity: Math.min(1, links / Math.max(1, length)), punctuation: (text.match(/[,;:]/g) || []).length / Math.max(1, length) * 100,
      digits: (text.match(/\d/g) || []).length / Math.max(1, length), uppercase: (text.match(/\p{Lu}/gu) || []).length / Math.max(1, length),
      fontRatio: size / bodySize, sameFont: +(Math.round(size) === bodySize), bold: +((parseInt(style.fontWeight, 10) || 400) >= 600),
      left: rect.left / docWidth, centerX: (rect.left + rect.width / 2) / docWidth, width: rect.width / docWidth, heightShare: rect.height / docHeight,
      top: (rect.top + scrollY) / docHeight, columnOffset: Math.min(2, Math.abs(rect.left - columnLeft) / docWidth), inColumn: +(Math.abs(rect.left - columnLeft) <= 48),
      main: place.main, article: place.article, nav: place.nav, aside: place.aside, footer: place.footer, header: place.header, form: place.form, dialog: place.dialog,
      list: place.list, negative: Math.min(4, place.negative), positive: Math.min(4, place.positive), fixed: place.fixed, depth: Math.min(40, place.depth),
      parentShare: (parentText.get(element.parentElement) || 0) / totalText, textShare: length / totalText, siblings: Math.min(60, element.parentElement?.children.length || 0),
      prevLength: Math.log1p(previous?.text?.length || 0), nextLength: Math.log1p(next?.text?.length || 0), position: index / Math.max(1, blocks.length),
      titleMatch: +(length > 8 && title.includes(text.toLowerCase().slice(0, 60)))
    };
    return { index, element, kind, tag: tag.toLowerCase(), text, features };
  });
  globalThis.__apsaReaderBlocks = output;
  // Builds an article from the blocks the model kept. It reads the live page, in this
  // isolated world, and takes text only.
  globalThis.__apsaReaderBuild = indices => {
    const absolute = value => {
      try {
        const url = new URL(value, document.baseURI);
        return url.protocol === "http:" || url.protocol === "https:" ? url.href : "";
      } catch (_) { return ""; }
    };
    const runsOf = element => {
      const runs = [];
      const walk = (node, marks) => {
        if (node.nodeType === Node.TEXT_NODE) {
          const text = node.textContent.replace(/[\s\u00a0]+/g, " ");
          if (text) runs.push({ t: text, ...marks });
          return;
        }
        if (node.nodeType !== Node.ELEMENT_NODE || SKIP.has(node.tagName.toUpperCase()) || node.tagName === "IMG") return;
        if (node.tagName === "BR") { runs.push({ t: "\n", ...marks }); return; }
        const next = { ...marks };
        if (node.tagName === "A" && node.getAttribute("href")) { const href = absolute(node.getAttribute("href")); if (href) next.h = href; }
        if (node.tagName === "B" || node.tagName === "STRONG") next.b = 1;
        if (node.tagName === "I" || node.tagName === "EM") next.i = 1;
        if (node.tagName === "CODE" || node.tagName === "KBD" || node.tagName === "SAMP") next.c = 1;
        for (const child of node.childNodes) walk(child, next);
      };
      for (const child of element.childNodes) walk(child, {});
      return runs;
    };
    const result = [];
    let title = "";
    for (const index of indices) {
      const block = output[index];
      if (!block) continue;
      const { element, kind, tag } = block;
      if (kind === "image") {
        const source = absolute(element.currentSrc || element.getAttribute("src") || "");
        if (source) result.push({ k: "img", src: source, alt: element.getAttribute("alt") || "", cap: "" });
      } else if (kind === "table") {
        result.push({ k: "table", rows: [...element.querySelectorAll("tr")].slice(0, 200).map(row => [...row.children].map(cell => clean(cell.textContent))) });
      } else if (/^h[1-6]$/.test(tag)) {
        if (tag === "h1" && !title) title = block.text;
        else result.push({ k: "h", l: Number(tag[1]), runs: runsOf(element) });
      } else if (tag === "pre") result.push({ k: "pre", t: element.textContent.replace(/\n+$/, "") });
      else if (tag === "li") result.push({ k: "li", n: "•", d: 0, runs: runsOf(element) });
      else if (tag === "blockquote") result.push({ k: "q", runs: runsOf(element) });
      else result.push({ k: "p", runs: runsOf(element) });
    }
    return { title: title || clean(document.title), byline: "", site: "", url: location.href, blocks: result };
  };
  return output.map(({ index, kind, tag, text, features }) => ({ index, kind, tag, text, features }));
})()
