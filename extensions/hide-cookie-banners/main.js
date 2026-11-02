const unlock = () => { for (const element of [document.documentElement, document.body]) if (element) element.style.setProperty('overflow', 'auto', 'important'); };
if (document.querySelector('#onetrust-banner-sdk, #CybotCookiebotDialog, .fc-consent-root, #didomi-host, .qc-cmp2-container, #usercentrics-root, .cc-window')) unlock();
