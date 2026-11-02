const video = () => [...document.querySelectorAll('video')].sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
document.addEventListener('keydown', event => {
  const target = event.target;
  if (event.metaKey || event.ctrlKey || event.altKey || target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName)) return;
  const current = video();
  if (!current) return;
  const key = event.key.toLowerCase();
  if (key === 's') current.playbackRate = Math.max(0.25, Math.round((current.playbackRate - 0.25) * 100) / 100);
  else if (key === 'd') current.playbackRate = Math.min(4, Math.round((current.playbackRate + 0.25) * 100) / 100);
  else if (key === 'r') current.playbackRate = 1;
  else return;
  event.stopPropagation();
}, true);
