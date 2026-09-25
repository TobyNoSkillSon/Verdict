#!/bin/bash
# Build the native menu-bar app locally. Never touch the installed/running app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="${VERDICT_APP_PATH:-$ROOT/dist/Verdict.app}"
case "$APP" in /Applications/*|"$HOME"/Applications/*)
  echo 'Refusing to install from build.sh; use scripts/install.sh after review.' >&2; exit 1;;
esac
IDENTITY="${VERDICT_SIGN_IDENTITY:--}"
scripts/build-helper.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  /Library/Developer/CommandLineTools/usr/bin/swift build --build-system native -c release --product Verdict
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  /Library/Developer/CommandLineTools/usr/bin/swift build --build-system native -c release --product verdict-cli
STAGE="$(mktemp -d "$ROOT/.build/.verdict-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/Verdict.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Helpers"
cp .build/release/Verdict "$BUNDLE/Contents/MacOS/Verdict"
# The `verdict` command line; install.sh links ~/.local/bin/verdict to it.
cp .build/release/verdict-cli "$BUNDLE/Contents/Helpers/verdict"
cp .build/release-helper/verdict-helper "$BUNDLE/Contents/MacOS/verdict-helper"
cp .build/release-helper/mlx.metallib "$BUNDLE/Contents/Resources/mlx.metallib"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
if [[ -n "${VERDICT_RELEASE_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERDICT_RELEASE_VERSION" "$BUNDLE/Contents/Info.plist" >/dev/null
fi
cp Resources/models.json Resources/benchmarks.json Resources/SKILL.md "$BUNDLE/Contents/Resources/"
cp clients/python/verdict.py "$BUNDLE/Contents/Resources/verdict.py"
ICONSET="$STAGE/Verdict.iconset"; mkdir -p "$ICONSET"
xcrun swift scripts/icon.swift "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size*2))" "$((size*2))" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/Verdict.icns"
codesign --force --sign "$IDENTITY" "$BUNDLE/Contents/MacOS/verdict-helper" >/dev/null
codesign --force --sign "$IDENTITY" "$BUNDLE/Contents/Helpers/verdict" >/dev/null
codesign --force --sign "$IDENTITY" "$BUNDLE" >/dev/null
codesign --verify --deep --strict "$BUNDLE"
mkdir -p "$(dirname "$APP")"
PREVIOUS=''
if [[ -e "$APP" ]]; then
  PREVIOUS="$(dirname "$APP")/.Verdict.app.previous.$(date +%Y%m%d%H%M%S).$$"
  mv "$APP" "$PREVIOUS"
fi
if ! mv "$BUNDLE" "$APP"; then
  [[ -z "$PREVIOUS" ]] || mv "$PREVIOUS" "$APP"
  echo 'Build finished but staging the app failed; previous app restored.' >&2; exit 1
fi
echo "Built $APP (native helper + Metal library + verdict CLI; not installed)"
[[ -z "$PREVIOUS" ]] || echo "Previous build retained at $PREVIOUS"
