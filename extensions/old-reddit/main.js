if (!location.pathname.startsWith('/media') && !location.pathname.startsWith('/poll')) location.replace('https://old.reddit.com' + location.pathname + location.search + location.hash);
