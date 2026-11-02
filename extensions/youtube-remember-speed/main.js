const key = 'apsa-youtube-speed';
document.addEventListener('ratechange', event => {
  if (event.target instanceof HTMLVideoElement && event.target.playbackRate !== 1) localStorage.setItem(key, String(event.target.playbackRate));
  else if (event.target instanceof HTMLVideoElement && event.isTrusted && document.hasFocus()) localStorage.removeItem(key);
}, true);
document.addEventListener('loadedmetadata', event => {
  const speed = Number(localStorage.getItem(key));
  if (event.target instanceof HTMLVideoElement && speed > 0) event.target.playbackRate = speed;
}, true);
