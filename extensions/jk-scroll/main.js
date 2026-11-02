const typing = target => target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName);
document.addEventListener('keydown', event => {
  if (event.metaKey || event.ctrlKey || event.altKey || typing(event.target)) return;
  const step = { j: 1, k: -1 }[event.key];
  if (!step) return;
  window.scrollBy({ top: step * innerHeight * 0.4, behavior: 'smooth' });
  event.stopPropagation();
}, true);
