const clean = () => {
  for (const link of document.querySelectorAll('a[href*="/url?"]')) {
    const target = new URL(link.href).searchParams.get('q') || new URL(link.href).searchParams.get('url');
    if (target && /^https?:/.test(target)) link.href = target;
  }
  for (const link of document.querySelectorAll('a[ping]')) link.removeAttribute('ping');
};
clean();
new MutationObserver(clean).observe(document.body, { childList: true, subtree: true });
