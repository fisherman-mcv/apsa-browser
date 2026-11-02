const key = 'apsa-youtube-speed';
// YouTube sets 1× itself when a new video loads; only later changes are the viewer's.
let loadedAt = 0;
document.addEventListener('loadstart', () => { loadedAt = Date.now(); }, true);
document.addEventListener('loadedmetadata', event => {
  const speed = Number(localStorage.getItem(key));
  if (event.target instanceof HTMLVideoElement && speed > 0) event.target.playbackRate = speed;
}, true);
document.addEventListener('ratechange', event => {
  if (event.target instanceof HTMLVideoElement && Date.now() - loadedAt > 1500) localStorage.setItem(key, String(event.target.playbackRate));
}, true);
