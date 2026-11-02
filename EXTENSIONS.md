# Apsa extensions

An Apsa extension is a folder with an `extension.json` file and the scripts and
styles it names. Extensions run only in Apsa Browser, through WebKit.

```json
{
  "format": 1,
  "id": "com.example.my-extension",
  "name": "My Extension",
  "description": "One sentence shown in Settings.",
  "version": "1.0",
  "matches": ["*://*.example.com/*"],
  "excludeMatches": ["*://*.example.com/admin/*"],
  "scripts": ["main.js"],
  "styles": ["style.css"],
  "runAt": "end",
  "allFrames": false
}
```

- `format` is 1.
- `id` is unique. A folder in your extensions folder with the same id as a built-in
  extension replaces it.
- `matches` lists the pages the extension runs on: `<all_urls>`, or
  `scheme://host/path`. The scheme can be `*` (http or https), the host can start
  with `*.` to include subdomains, and `*` in the path matches anything.
- `excludeMatches` (optional) lists pages to leave alone even when `matches` covers them.
- `scripts` and `styles` are files inside the folder. Styles are added when the
  page starts loading. Scripts run when the document is ready (`"runAt": "end"`,
  the default) or before the page's own scripts (`"runAt": "start"`).
- `allFrames: true` also runs the extension inside frames.

Each extension runs in its own WebKit content world. It sees and changes the
page's DOM, but not the page's JavaScript variables or other extensions. There is
no background page and no special API: an extension is a plain script and style.

Extensions are off until turned on in Settings → Extensions. They don't run in
private windows, and changes apply to tabs opened afterwards.

Your extensions go in `~/Library/Application Support/Apsa Browser/Extensions/`.
Settings → Extensions → Show Extensions Folder opens it. The built-in ones are in
`extensions/` in this repository.
