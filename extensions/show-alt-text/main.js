document.addEventListener('mouseover', event => {
  const image = event.target;
  if (image instanceof HTMLImageElement && image.alt && !image.title) image.title = image.alt;
}, true);
