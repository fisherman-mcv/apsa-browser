# Apsa Browser

A small macOS browser on the system WebKit, in the spirit of Safari.

- Built-in ad and tracker blocking (EasyList and EasyPrivacy), with a per-site switch
- Privacy levels: Standard, Strict and Maximum, plus detailed settings, private windows and a SOCKS5 proxy
- Reader mode that refuses pages where it finds no article
- Page translation on the Mac (macOS 15 or later)
- Tabs in a sidebar with folders, session restore, history, bookmarks
- Passwords in the macOS keychain, filled after Touch ID
- Themes, and an optional HTML interface you can restyle with `chrome.css`
- Extensions in its own simple format, 12 built in (see `EXTENSIONS.md`)
- English and Russian

## Build

Needs macOS 14 or later and the Xcode command line tools.

```sh
sh build.sh
open "build/Apsa Browser.app"
```

The app is signed ad hoc, so it runs on the Mac that built it.

## Tests

Each `*Tests.swift` file is a standalone program that runs without opening windows. Compile it together with the source files it uses, for example:

```sh
xcrun swiftc NavigationTests.swift ApsaNavigation.swift -parse-as-library -o /tmp/navtests && /tmp/navtests
```

## Status

Made by one person and not actively maintained. Issues and pull requests may go unanswered. Ad-blocking rules do not update on their own.

## License

MIT for the project's code. See `THIRD_PARTY_NOTICES.md` for bundled third-party parts.
