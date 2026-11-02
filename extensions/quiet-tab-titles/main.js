const quiet = () => {
  const clean = document.title.replace(/^\(\d+\+?\)\s*/, '');
  if (clean !== document.title) document.title = clean;
};
quiet();
const head = document.querySelector('head');
if (head) new MutationObserver(quiet).observe(head, { childList: true, subtree: true, characterData: true });
