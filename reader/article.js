// Runs after Readability.js in its own content world, on a copy of the page. Turns the
// article into plain blocks for the native reading page. Page markup never reaches
// the browser interface, and only web links and images are kept.
const MAX_BLOCKS = 4000;
const absolute = value => {
  try {
    const url = new URL(value, document.baseURI);
    return url.protocol === "http:" || url.protocol === "https:" ? url.href : "";
  } catch (_) { return ""; }
};
const parseArticle = () => {
  const article = new Readability(document.cloneNode(true), { charThreshold: 180 }).parse();
  if (!article || (article.textContent || "").trim().length < 180) return null;
  const root = new DOMParser().parseFromString(article.content, "text/html").body;
  const blocks = [];
  const add = block => { if (blocks.length < MAX_BLOCKS) blocks.push(block); };

  const runsOf = element => {
    const runs = [];
    const walk = (node, marks) => {
      if (node.nodeType === Node.TEXT_NODE) {
        const text = node.textContent.replace(/[\s\u00a0]+/g, " ");
        if (text) runs.push({ t: text, ...marks });
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const tag = node.tagName;
      if (tag === "BR") { runs.push({ t: "\n", ...marks }); return; }
      if (tag === "IMG" || tag === "SCRIPT" || tag === "STYLE") return;
      const next = { ...marks };
      if (tag === "A" && node.getAttribute("href")) { const href = absolute(node.getAttribute("href")); if (href) next.h = href; }
      if (tag === "B" || tag === "STRONG") next.b = 1;
      if (tag === "I" || tag === "EM") next.i = 1;
      if (tag === "CODE" || tag === "KBD" || tag === "SAMP") next.c = 1;
      for (const child of node.childNodes) walk(child, next);
    };
    for (const child of element.childNodes) walk(child, {});
    return runs;
  };
  const hasText = runs => runs.some(run => run.t.trim());
  const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DETAILS|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|SUMMARY|TABLE|UL)$/;
  const image = (element, caption = "") => {
    const source = absolute(element.getAttribute("src") || element.getAttribute("data-src") || "");
    if (source) add({ k: "img", src: source, alt: element.getAttribute("alt") || "", cap: caption });
  };
  const list = (element, depth) => {
    let number = parseInt(element.getAttribute("start") || "1", 10) || 1;
    for (const item of element.children) {
      if (item.tagName !== "LI") continue;
      const nested = [...item.children].filter(child => child.tagName === "UL" || child.tagName === "OL");
      nested.forEach(child => child.remove());
      const runs = runsOf(item);
      if (hasText(runs)) add({ k: "li", n: element.tagName === "OL" ? `${number}.` : "•", d: depth, runs });
      number += 1;
      nested.forEach(child => list(child, depth + 1));
    }
  };
  const walk = element => {
    for (const child of element.children) {
      const tag = child.tagName;
      if (/^H[1-6]$/.test(tag)) {
        const runs = runsOf(child);
        if (hasText(runs)) add({ k: "h", l: Number(tag[1]), runs });
      } else if (tag === "UL" || tag === "OL") list(child, 0);
      else if (tag === "BLOCKQUOTE") {
        const runs = runsOf(child);
        if (hasText(runs)) add({ k: "q", runs });
      } else if (tag === "PRE") add({ k: "pre", t: child.textContent.replace(/\n+$/, "") });
      else if (tag === "TABLE") {
        const rows = [...child.querySelectorAll("tr")].map(row => [...row.children].map(cell => cell.textContent.replace(/[\s\u00a0]+/g, " ").trim()));
        if (rows.length) add({ k: "table", rows: rows.slice(0, 200) });
      } else if (tag === "FIGURE") {
        const caption = child.querySelector("figcaption")?.textContent.replace(/[\s\u00a0]+/g, " ").trim() || "";
        const picture = child.querySelector("img");
        if (picture) image(picture, caption);
        else if (caption) add({ k: "p", runs: [{ t: caption }] });
      } else if (tag === "IMG") image(child);
      else if ([...child.children].some(inner => BLOCK.test(inner.tagName))) walk(child);
      else if (tag !== "HR") {
        child.querySelectorAll("img").forEach(picture => image(picture));
        const runs = runsOf(child);
        if (hasText(runs)) add({ k: "p", runs });
      }
    }
  };
  walk(root);
  const text = article.textContent || "";
  return { length: text.length, words: text.trim().split(/\s+/).length, title: article.title || document.title || "", byline: article.byline || "", site: article.siteName || "", url: location.href, blocks };
};
return (() => {
  try {
    const result = parseArticle();
    return result ? JSON.stringify(result) : "";
  } catch (_) { return ""; }
})();
