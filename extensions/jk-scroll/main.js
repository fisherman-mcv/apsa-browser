const typing = target => target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName);
// Listens last and only when the page did nothing with the key, so site shortcuts win.
window.addEventListener('keydown', event => {
  if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || typing(event.target)) return;
  const step = { j: 1, k: -1 }[event.key];
  if (step) window.scrollBy({ top: step * innerHeight * 0.4, behavior: 'smooth' });
});
