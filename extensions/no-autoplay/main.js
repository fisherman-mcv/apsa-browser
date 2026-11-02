let interacted = false;
for (const type of ['pointerdown', 'keydown']) document.addEventListener(type, () => { interacted = true; }, true);
document.addEventListener('play', event => { if (!interacted && event.target instanceof HTMLVideoElement) event.target.pause(); }, true);
