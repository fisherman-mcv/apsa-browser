#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR="$SCRIPT_DIR/build"
APP_DIR="$ROOT_DIR/Apsa Browser.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
mkdir -p "$RESOURCES_DIR/translate"
cp "$SCRIPT_DIR/translate/translate.js" "$RESOURCES_DIR/translate/"
mkdir -p "$RESOURCES_DIR/reader"
cp "$SCRIPT_DIR/reader/Readability.js" "$SCRIPT_DIR/reader/article.js" "$SCRIPT_DIR/reader/extract.js" "$RESOURCES_DIR/reader/"
rm -rf "$RESOURCES_DIR/reader/ReaderBlocks.mlmodelc"
cp -R "$SCRIPT_DIR/reader/ReaderBlocks.mlmodelc" "$RESOURCES_DIR/reader/"
mkdir -p "$RESOURCES_DIR/adblock"
cp "$SCRIPT_DIR/adblock/rules.json.deflate" "$RESOURCES_DIR/adblock/"
rm -rf "$RESOURCES_DIR/extensions"
cp -R "$SCRIPT_DIR/extensions" "$RESOURCES_DIR/extensions"
mkdir -p "$RESOURCES_DIR/chrome"
cp "$SCRIPT_DIR/chrome/chrome.html" "$SCRIPT_DIR/chrome/chrome.css" "$SCRIPT_DIR/chrome/chrome.js" "$RESOURCES_DIR/chrome/"

xcrun swiftc \
  "$SCRIPT_DIR/ApsaBrowser.swift" \
  "$SCRIPT_DIR/ApsaTheme.swift" \
  "$SCRIPT_DIR/ApsaPopup.swift" \
  "$SCRIPT_DIR/ApsaExtensions.swift" \
  "$SCRIPT_DIR/ApsaLocalization.swift" \
  "$SCRIPT_DIR/ApsaChrome.swift" \
  "$SCRIPT_DIR/ApsaFind.swift" \
  "$SCRIPT_DIR/ApsaProgressBar.swift" \
  "$SCRIPT_DIR/ApsaPrivacy.swift" \
  "$SCRIPT_DIR/ApsaTranslation.swift" \
  "$SCRIPT_DIR/ApsaReader.swift" \
  "$SCRIPT_DIR/ApsaFastFullscreen.swift" \
  "$SCRIPT_DIR/ApsaContentBlocker.swift" \
  "$SCRIPT_DIR/ApsaSessionStore.swift" \
  "$SCRIPT_DIR/ApsaPasswordStore.swift" \
  "$SCRIPT_DIR/ApsaPasswordAutofill.swift" \
  "$SCRIPT_DIR/ApsaPasswordsPage.swift" \
  "$SCRIPT_DIR/ApsaResourcePressure.swift" \
  "$SCRIPT_DIR/ApsaHistoryStore.swift" \
  "$SCRIPT_DIR/ApsaHistoryPage.swift" \
  "$SCRIPT_DIR/ApsaBookmarkStore.swift" \
  "$SCRIPT_DIR/ApsaBookmarksUI.swift" \
  "$SCRIPT_DIR/ApsaSelection.swift" \
  "$SCRIPT_DIR/ApsaNavigation.swift" \
  -O \
  -framework AppKit \
  -framework WebKit \
  -framework Security \
  -framework LocalAuthentication \
  -framework CoreML \
  -framework Network \
  -framework SwiftUI \
  -framework NaturalLanguage \
  -Xlinker -weak_framework -Xlinker Translation \
  -o "$MACOS_DIR/ApsaBrowser"

# Generated from the site's icon.svg by make-icon.swift.
cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

codesign --force --sign - "$APP_DIR"
printf '%s\n' "$APP_DIR"
