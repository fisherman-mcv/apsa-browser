// Builds the evaluation corpus. Each site names the selector that holds its real
// content, so labels come from the page's own structure rather than hand marking.
// News addresses come from live feeds, so the set does not go stale.
import { writeFile } from "node:fs/promises";

const wiki = { gold: ".mw-parser-output", exclude: ".infobox,.navbox,.reflist,.mw-editsection,.toc,.sidebar,.thumb,.hatnote,.ambox,.metadata,.mw-references-wrap,.reference,.navigation-not-searchable,.vector-toc" };
const FIXED = [
  ["https://en.wikipedia.org/wiki/WebKit", wiki, "wiki"], ["https://en.wikipedia.org/wiki/Photosynthesis", wiki, "wiki"], ["https://en.wikipedia.org/wiki/Roman_Empire", wiki, "wiki"],
  ["https://ru.wikipedia.org/wiki/Фотосинтез", wiki, "wiki"], ["https://de.wikipedia.org/wiki/Berlin", wiki, "wiki"], ["https://fr.wikipedia.org/wiki/Paris", wiki, "wiki"],
  ...["Web/CSS/display", "Web/HTTP/Caching", "Web/JavaScript/Guide/Closures", "Web/API/Fetch_API"].map(p => [`https://developer.mozilla.org/en-US/docs/${p}`, { gold: ".reference-layout__body", exclude: ".article-footer,.bc-table,.bc-specs,.code-example .language-name" }, "docs"]),
  ["https://docs.python.org/3/library/asyncio-task.html", { gold: "div.body", exclude: ".headerlink" }, "docs"], ["https://docs.python.org/3/tutorial/classes.html", { gold: "div.body", exclude: ".headerlink" }, "docs"],
  ["https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html", { gold: "main", exclude: ".buttons" }, "docs"], ["https://doc.rust-lang.org/book/ch10-00-generics.html", { gold: "main", exclude: ".buttons" }, "docs"],
  ["https://go.dev/doc/effective_go", { gold: "article,.Article", exclude: "nav" }, "docs"], ["https://www.postgresql.org/docs/current/tutorial-join.html", { gold: "#docContent .sect1,.sect1", exclude: ".navheader,.navfooter" }, "docs"],
  ["https://nodejs.org/en/learn/asynchronous-work/overview-of-blocking-vs-non-blocking", { gold: "main", exclude: "nav,footer,aside" }, "docs"],
  ["https://www.rfc-editor.org/rfc/rfc9110.html", { gold: "pre,.rfc,section", exclude: ".toc,#toc" }, "long"], ["https://www.gnu.org/philosophy/free-sw.html", { gold: "#content", exclude: "#edu-content,.infobox,.translators-notes" }, "legacy"],
  ["https://www.paulgraham.com/greatwork.html", { gold: "table font", exclude: "" }, "legacy"], ["https://www.paulgraham.com/ds.html", { gold: "table font", exclude: "" }, "legacy"], ["https://danluu.com/p95-skill/", { gold: "main,article", exclude: "nav,footer" }, "legacy"],
  ["https://motherfuckingwebsite.com/", { gold: "body", exclude: "" }, "legacy"], ["https://blog.cr.yp.to/20240612-bibkeys.html", { gold: "body", exclude: "" }, "legacy"], ["https://www.w3.org/TR/CSS2/box.html", { gold: "body", exclude: ".navbar,.toc,address" }, "legacy"],
  ["https://webkit.org/blog/15865/webkit-features-in-safari-18-0/", { gold: ".bodycopy,article .post-content", exclude: "" }, "blog"], ["https://blog.rust-lang.org/2024/02/19/2023-Rust-Annual-Survey-2023-results.html", { gold: ".post", exclude: "header" }, "blog"], ["https://martinfowler.com/articles/microservices.html", { gold: ".paperBody,h1", exclude: ".sidebar,aside" }, "blog"], ["https://www.joelonsoftware.com/2000/04/06/things-you-should-never-do-part-i/", { gold: ".entry-content,h1", exclude: "" }, "blog"], ["https://jvns.ca/blog/2024/02/16/popular-git-config-options/", { gold: "article,.post", exclude: "nav,footer" }, "blog"], ["https://kubernetes.io/docs/concepts/overview/", { gold: ".td-content", exclude: ".td-page-meta,.feedback--title" }, "docs"], ["https://react.dev/learn/thinking-in-react", { gold: "article", exclude: "nav,aside" }, "docs"], ["https://docs.djangoproject.com/en/5.0/topics/db/queries/", { gold: "#docs-content", exclude: ".headerlink" }, "docs"],
  ["https://github.com/WebKit/WebKit", { gold: "article.markdown-body", exclude: "" }, "repo"], ["https://github.com/torvalds/linux/blob/master/README", { gold: "article.markdown-body,#read-only-cursor-text-area", exclude: "" }, "repo"], ["https://github.com/rust-lang/rust", { gold: "article.markdown-body", exclude: "" }, "repo"], ["https://github.com/sveltejs/svelte", { gold: "article.markdown-body", exclude: "" }, "repo"],
  ["https://stackoverflow.com/questions/11227809/why-is-processing-a-sorted-array-faster-than-processing-an-unsorted-array", { gold: ".question .s-prose,.answer .s-prose,h1", exclude: "" }, "forum"], ["https://stackoverflow.com/questions/927358/how-do-i-undo-the-most-recent-local-commits-in-git", { gold: ".question .s-prose,.answer .s-prose,h1", exclude: "" }, "forum"],
  ["https://stackoverflow.com/questions/231767/what-does-the-yield-keyword-do-in-python", { gold: ".question .s-prose,.answer .s-prose,h1", exclude: "" }, "forum"], ["https://stackoverflow.com/questions/1642028/what-is-the-operator-in-c-c", { gold: ".question .s-prose,.answer .s-prose,h1", exclude: "" }, "forum"], ["https://news.ycombinator.com/item?id=121003", { gold: ".titleline,.commtext", exclude: "" }, "forum"], ["https://news.ycombinator.com/item?id=3078128", { gold: ".titleline,.commtext", exclude: "" }, "forum"], ["https://news.ycombinator.com/item?id=8863", { gold: ".titleline,.commtext", exclude: "" }, "forum"], ["https://news.ycombinator.com/item?id=38309611", { gold: ".titleline,.commtext", exclude: "" }, "forum"],
  ["https://habr.com/ru/articles/754050/", { gold: ".article-formatted-body,h1", exclude: "" }, "ru"], ["https://habr.com/ru/articles/541014/", { gold: ".article-formatted-body,h1", exclude: "" }, "ru"],
  ["https://www.nasa.gov/humans-in-space/20-breakthroughs-from-20-years-of-science-aboard-the-international-space-station/", { gold: ".entry-content,.wp-block-post-content,article", exclude: "nav,footer,aside" }, "science"], ["https://www.nature.com/articles/d41586-023-00340-6", { gold: ".c-article-body,article", exclude: "aside,nav,.c-article-recommendations" }, "science"],
  ["https://www.simplyrecipes.com/recipes/spaghetti_alla_carbonara/", { gold: "#article-content,.article-content,article", exclude: "nav,aside,footer" }, "recipe"], ["https://www.bbcgoodfood.com/recipes/ultimate-spaghetti-carbonara-recipe", { gold: "main article,article", exclude: "nav,aside,footer" }, "recipe"],
  // Nothing here is an article, so the right answer is to show nothing.
  ...["https://www.google.com/", "https://duckduckgo.com/", "https://github.com/login", "https://www.bbc.com/", "https://www.apple.com/", "https://www.youtube.com/", "https://en.wikipedia.org/wiki/Special:Search", "https://news.ycombinator.com/", "https://www.reddit.com/login/", "https://www.amazon.com/"].map(url => [url, { refuse: true }, "refuse"])
];
const FEEDS = [
  ["https://feeds.bbci.co.uk/news/world/rss.xml", { gold: "article [data-component='text-block'],article h1", exclude: "" }, "news", /bbc\.(co\.uk|com)\/news\/articles\//],
  ["https://www.theguardian.com/world/rss", { gold: "#maincontent,[data-gu-name='body'],h1", exclude: "aside,figure,[data-print-layout='hide']" }, "news", /theguardian\.com\/.*\/\d{4}\//],
  ["https://feeds.npr.org/1001/rss.xml", { gold: "#storytext,h1", exclude: "aside,.bucketwrap,.credit-caption" }, "news", /npr\.org\/\d{4}\//],
  ["https://feeds.arstechnica.com/arstechnica/index", { gold: ".post-content,h1", exclude: "aside,.ad-wrapper" }, "news", /arstechnica\.com/],
  ["https://www.aljazeera.com/xml/rss/all.xml", { gold: ".wysiwyg,h1", exclude: "aside,.more-on" }, "news", /aljazeera\.com\/news\//],
  ["https://meduza.io/rss/all", { gold: "[class*='GeneralMaterial-article'],[class*='SimpleBlock'],h1", exclude: "" }, "ru", /meduza\.io\/(news|feature)\//],
  ["https://lenta.ru/rss/news", { gold: ".topic-body__content,h1", exclude: "aside" }, "ru", /lenta\.ru\/news\//],
  ["https://meta.discourse.org/latest.rss", { gold: ".cooked,h1", exclude: "aside" }, "forum", /meta\.discourse\.org\/t\//],
  ["https://habr.com/ru/rss/articles/", { gold: ".article-formatted-body,h1", exclude: "" }, "ru", /habr\.com\/ru\/articles\//],
  ["https://rssexport.rbc.ru/rbcnews/news/30/full.rss", { gold: ".article__text,h1", exclude: "aside,.article__inline-item" }, "ru", /rbc\.ru\/[a-z_]+\/\d/],
  ["https://www.kommersant.ru/RSS/news.xml", { gold: ".doc__body,.article_text,h1", exclude: "aside" }, "ru", /kommersant\.ru\/doc\//],
  ["https://techcrunch.com/feed/", { gold: ".entry-content,.wp-block-post-content,h1", exclude: "aside,.wp-block-tc23-podcast-player" }, "news", /techcrunch\.com\/\d{4}\//]
];
const corpus = FIXED.map(([url, target, category]) => ({ url, category, ...target }));
for (const [feed, target, category, pattern] of FEEDS) {
  try {
    const xml = await (await fetch(feed, { headers: { "user-agent": "Mozilla/5.0" }, signal: AbortSignal.timeout(20000) })).text();
    const links = [...xml.matchAll(/<link>\s*(?:<!\[CDATA\[)?\s*(https?:[^<\]\s]+)/g)].map(match => match[1].replace(/\?utm_.*$/, "").replace(/&amp;.*$/, "")).filter(link => pattern.test(link));
    for (const url of [...new Set(links)].slice(0, 3)) corpus.push({ url, category, ...target });
  } catch (error) { console.error("feed failed", feed, String(error).slice(0, 80)); }
}
await writeFile(process.argv[2], JSON.stringify(corpus, null, 1));
console.log(corpus.length, "pages");
