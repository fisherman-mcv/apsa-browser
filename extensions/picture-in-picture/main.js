document.addEventListener('keydown', event => {
  const target = event.target;
  if (event.key.toLowerCase() !== 'p' || event.metaKey || event.ctrlKey || event.altKey || target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName)) return;
  const video = [...document.querySelectorAll('video')].sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
  if (!video || !video.webkitSupportsPresentationMode?.('picture-in-picture')) return;
  video.webkitSetPresentationMode(video.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
  event.stopPropagation();
}, true);
