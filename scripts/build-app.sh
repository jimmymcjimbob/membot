#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MemBot
APP=build/MemBot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MemBot" "$APP/Contents/MacOS/MemBot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
