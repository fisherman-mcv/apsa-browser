for (const type of ['copy', 'cut', 'contextmenu', 'selectstart', 'dragstart']) document.addEventListener(type, event => event.stopPropagation(), true);
