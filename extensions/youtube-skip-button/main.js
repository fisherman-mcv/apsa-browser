// A light check twice a second rather than reacting to every change on YouTube's busy page.
// YouTube may ignore clicks that a script makes; then this does nothing.
setInterval(() => {
  if (document.querySelector('.html5-video-player.ad-showing')) document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern')?.click();
}, 500);
