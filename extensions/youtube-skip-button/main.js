new MutationObserver(() => document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern')?.click())
  .observe(document.documentElement, { childList: true, subtree: true });
