// Runs in its own content world. Sends text blocks to the browser as they come near the
// screen and swaps in the translation, keeping the page's own links and emphasis.
(() => {
  if (globalThis.apsaTranslate) return;
  const TAGS = new Set(["P", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "BLOCKQUOTE", "TD", "TH", "DD", "DT", "FIGCAPTION", "CAPTION", "SUMMARY", "LABEL", "A", "BUTTON", "DIV", "SPAN", "SECTION", "ARTICLE"]);
  const SKIP = "script,style,noscript,template,code,pre,kbd,samp,var,textarea,input,select,svg,math,[contenteditable],[translate=no],.notranslate";
  const INLINE = new Set(["A", "ABBR", "B", "BDI", "BDO", "BR", "CITE", "DFN", "EM", "FONT", "I", "INS", "MARK", "NOBR", "Q", "S", "SMALL", "SPAN", "STRONG", "SUB", "SUP", "TIME", "U", "WBR", "CODE", "KBD", "SAMP", "VAR", "IMG"]);
  const MAX_BATCH_BLOCKS = 40;
  const MAX_BATCH_CHARS = 12000;
  const MAX_BLOCK_CHARS = 5000;
  let active = false;
  let nextID = 1;
  let queue = [];
  let timer = null;
  const known = new WeakMap();
  const byID = new Map();
  const post = message => window.webkit.messageHandlers.apsaTranslate.postMessage(message);

  const isBlock = element => {
    if (!TAGS.has(element.tagName) || element.closest(SKIP) || known.has(element)) return false;
    const text = element.textContent.trim();
    if (!text || text.length > MAX_BLOCK_CHARS || !/\p{L}{2}/u.test(text)) return false;
    // Only the smallest block is taken: inline-only content, with some own text.
    if ([...element.children].some(child => !INLINE.has(child.tagName))) return false;
    if (element.tagName !== "A" && element.tagName !== "BUTTON" && element.tagName !== "SPAN") return true;
    return !element.parentElement?.closest("p,li,h1,h2,h3,h4,h5,h6,blockquote,td,th,dd,dt,figcaption,caption,summary,label");
  };
  // Top-level inline elements stay real elements, so a link is still that link.
  const runsOf = element => {
    const runs = [];
    for (const node of element.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        if (node.textContent) runs.push({ t: node.textContent.replace(/\s+/g, " ") });
      } else if (node.nodeType === Node.ELEMENT_NODE && node.tagName !== "IMG" && node.tagName !== "BR" && node.textContent) {
        runs.push({ t: node.textContent.replace(/\s+/g, " "), e: [...element.childNodes].indexOf(node) });
      }
    }
    return runs;
  };
  const flush = () => {
    timer = null;
    if (!active || !queue.length) return;
    let chars = 0;
    const items = [];
    while (queue.length && items.length < MAX_BATCH_BLOCKS && chars < MAX_BATCH_CHARS) {
      const entry = queue.shift();
      if (!entry.element.isConnected || entry.sent) continue;
      entry.sent = true;
      const runs = entry.runs;
      chars += runs.reduce((sum, run) => sum + run.t.length, 0);
      items.push({ id: entry.id, runs });
    }
    if (items.length) post({ event: "blocks", items });
    if (queue.length) timer = setTimeout(flush, 60);
  };
  const enqueue = entry => {
    queue.push(entry);
    if (!timer) timer = setTimeout(flush, 120);
  };
  const near = new IntersectionObserver(entries => {
    for (const change of entries) {
      if (!change.isIntersecting) continue;
      near.unobserve(change.target);
      const entry = known.get(change.target);
      if (entry) enqueue(entry);
    }
  }, { rootMargin: "100% 0px" });
  const scan = root => {
    if (root.nodeType !== Node.ELEMENT_NODE) return;
    const candidates = root.matches?.("*") ? [root, ...root.querySelectorAll("*")] : [...root.querySelectorAll("*")];
    for (const element of candidates) {
      if (!isBlock(element)) continue;
      const entry = { id: nextID++, element, runs: runsOf(element), originals: [...element.childNodes], sent: false, done: false };
      if (!entry.runs.length) continue;
      known.set(element, entry);
      byID.set(entry.id, entry);
      near.observe(element);
    }
  };
  let mutationTimer = null;
  const added = new Set();
  const watcher = new MutationObserver(records => {
    for (const record of records) for (const node of record.addedNodes) if (node.nodeType === Node.ELEMENT_NODE && !node.__apsaTranslated) added.add(node);
    if (!mutationTimer && added.size) mutationTimer = setTimeout(() => {
      mutationTimer = null;
      for (const node of added) if (node.isConnected) scan(node);
      added.clear();
    }, 300);
  });

  globalThis.apsaTranslate = {
    start() {
      active = true;
      scan(document.body);
      watcher.observe(document.body, { childList: true, subtree: true });
      return { lang: document.documentElement.lang || "", sample: document.body.innerText.slice(0, 4000) };
    },
    apply(id, runs) {
      const entry = byID.get(id);
      if (!active || !entry || !entry.element.isConnected) return false;
      const nodes = runs.map(run => {
        const original = run.e === undefined ? null : entry.originals[run.e];
        if (!original || original.nodeType !== Node.ELEMENT_NODE) return document.createTextNode(run.t);
        const copy = original.cloneNode(false);
        copy.textContent = run.t;
        copy.__apsaTranslated = true;
        return copy;
      });
      entry.element.replaceChildren(...nodes);
      entry.done = true;
      return true;
    },
    stop() {
      active = false;
      watcher.disconnect();
      near.disconnect();
      queue = [];
      for (const entry of byID.values()) {
        if (entry.done && entry.element.isConnected) entry.element.replaceChildren(...entry.originals);
        known.delete(entry.element);
      }
      byID.clear();
      return true;
    }
  };
})();
