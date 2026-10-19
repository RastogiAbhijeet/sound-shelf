#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
mkdir -p .build/cache .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-cache"
swift build -c release -debug-info-format none --disable-sandbox --cache-path "$ROOT/.build/cache" --scratch-path "$ROOT/.build"
BIN=$(swift build -c release -debug-info-format none --disable-sandbox --cache-path "$ROOT/.build/cache" --scratch-path "$ROOT/.build" --show-bin-path)
APP="$ROOT/dist/SoundShelf.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SoundShelf" "$APP/Contents/MacOS/SoundShelf"
cp README.md "$APP/Contents/Resources/README.md"
mkdir -p "$APP/Contents/Resources/docs"
cp docs/microphone-feasibility.md "$APP/Contents/Resources/docs/"
cp -R BrowserExtension Bridge scripts "$APP/Contents/Resources/"
rm -f "$APP/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.soundshelf.app "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string SoundShelf "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string SoundShelf "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.4.9 "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 14 "$APP/Contents/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$APP/Contents/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool YES "$APP/Contents/Info.plist"
/usr/bin/plutil -insert NSAppleEventsUsageDescription -string 'SoundShelf controls playback and reads track information from Spotify and Music.' "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
printf 'Built %s\nLaunch with: open "%s"\n' "$APP" "$APP"
