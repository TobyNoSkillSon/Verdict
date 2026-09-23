#!/bin/bash
# Build Verdict.app into dist/ (or VERDICT_APP_PATH) and install the verdict CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${VERDICT_APP_PATH:-$PWD/dist/Verdict.app}"
IDENTITY="${VERDICT_SIGN_IDENTITY:--}"
xcrun swift build -c release
# Never replace a worker that is mid-judgement: quit the running app only when idle.
if pgrep -xq Verdict; then
  STATUS="$HOME/Library/Application Support/Verdict/status.json"
  if [[ -f "$STATUS" ]] && python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(1 if s.get("loading") else 0)' "$STATUS"; then
    osascript -e 'tell application "Verdict" to quit' >/dev/null 2>&1 || pkill -x Verdict || true
    for _ in $(seq 1 30); do pgrep -xq Verdict || break; sleep 0.2; done
  else
    echo 'Verdict is loading a model. Try again in a moment; installation left unchanged.' >&2; exit 1
  fi
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Verdict "$APP/Contents/MacOS/Verdict"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/worker.py Resources/models.json Resources/benchmarks.json Resources/runtime-requirements.txt Resources/SKILL.md "$APP/Contents/Resources/"
cp scripts/setup-backend.sh "$APP/Contents/Resources/"
ICONSET="$(mktemp -d)/Verdict.iconset"; mkdir -p "$ICONSET"
xcrun swift scripts/icon.swift "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Verdict.icns"
cp "$ICONSET/icon_512x512@2x.png" docs/images/icon-1024.png
codesign --force --sign "$IDENTITY" "$APP" >/dev/null
mkdir -p "$HOME/.local/bin"
install -m 755 client/verdict.py "$HOME/.local/bin/verdict"
# Python module at a fixed path any interpreter (including virtualenvs) can add with one line.
mkdir -p "$HOME/.local/share/verdict" && install -m 644 client/verdict.py "$HOME/.local/share/verdict/verdict.py"
# Also user site-packages, so plain `import verdict` works where user sites are enabled.
SITE="$(python3 -c 'import site; print(site.getusersitepackages() if site.ENABLE_USER_SITE else "")' 2>/dev/null || true)"
if [[ -n "$SITE" ]]; then mkdir -p "$SITE" && install -m 644 client/verdict.py "$SITE/verdict.py"; fi
echo "Built $APP; CLI ~/.local/bin/verdict; module ~/.local/share/verdict/verdict.py"
