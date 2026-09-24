#!/bin/bash
# Default: download the prebuilt, checksum-verified release matching this checkout's version
# (no Xcode needed). VERDICT_BUILD=source builds from this checkout instead (needs Xcode + Metal Toolchain).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${VERDICT_BUILD:-release}" == release ]]; then
  exec native/scripts/install-release.sh "${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
fi
[[ "${VERDICT_BUILD:-release}" == source ]] || { echo 'VERDICT_BUILD must be source or release' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Verdict requires Apple Silicon' >&2; exit 1; }
OS="$(sw_vers -productVersion)"; [[ "${OS%%.*}" -ge 14 ]] || { echo "Verdict requires macOS 14 or newer ($OS)" >&2; exit 1; }
if [[ ! -x /Library/Developer/CommandLineTools/usr/bin/swift ]]; then
  echo 'Stable Command Line Tools Swift is required. Fix: xcode-select --install' >&2; exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo 'Full Xcode is required. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer' >&2; exit 1
fi
if ! xcrun metal --version >/dev/null 2>&1; then
  echo 'Metal Toolchain is missing. Fix: xcodebuild -downloadComponent MetalToolchain' >&2; exit 1
fi
# Updating must work unattended (agents run `git pull && scripts/install.sh`), but never mid-load:
# quit a running Verdict only when it is not loading a model.
if pgrep -xq Verdict; then
  STATUS="$HOME/Library/Application Support/Verdict/status.json"
  if [[ -f "$STATUS" ]] && python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1])).get("loading") else 0)' "$STATUS"; then
    osascript -e 'tell application "Verdict" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq Verdict || break; sleep 0.2; done
    pgrep -xq Verdict && { echo 'Verdict did not quit; installation left unchanged.' >&2; exit 1; }
  else
    echo 'Verdict is loading a model. Try again in a moment; installation left unchanged.' >&2; exit 1
  fi
fi
scripts/build.sh
DEST=/Applications; [[ -w "$DEST" ]] || DEST="$HOME/Applications"; mkdir -p "$DEST"
STAGED="$DEST/.Verdict.app.install.$$"
[[ ! -e "$STAGED" ]] || { echo "Staging path exists: $STAGED" >&2; exit 1; }
ditto dist/Verdict.app "$STAGED"
codesign --verify --deep --strict "$STAGED"
PREVIOUS=''
if [[ -e "$DEST/Verdict.app" ]]; then
  PREVIOUS="$DEST/.Verdict.app.previous.$(date +%Y%m%d%H%M%S).$$"
  mv "$DEST/Verdict.app" "$PREVIOUS"
fi
if ! mv "$STAGED" "$DEST/Verdict.app"; then
  [[ -z "$PREVIOUS" ]] || mv "$PREVIOUS" "$DEST/Verdict.app"
  echo 'Install failed; previous app restored.' >&2; exit 1
fi
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/verdict"
install -m 644 client/verdict.py "$HOME/.local/share/verdict/verdict.py"
printf '%s\n' "$DEST/Verdict.app" > "$HOME/.local/share/verdict/app-path"
cat > "$HOME/.local/bin/verdict" <<'SH'
#!/bin/sh
VERDICT_APP="$(cat "$HOME/.local/share/verdict/app-path")"
export VERDICT_APP
exec python3 "$HOME/.local/share/verdict/verdict.py" "$@"
SH
chmod 755 "$HOME/.local/bin/verdict"
echo "Installed $DEST/Verdict.app and CLI ~/.local/bin/verdict"
open -g "$DEST/Verdict.app"
export VERDICT_APP="$DEST/Verdict.app"
for _ in $(seq 1 360); do
  out="$("$HOME/.local/bin/verdict" status 2>/dev/null || true)"
  if [[ "$out" == *"(mlx)"* ]]; then echo "ready: $out" | cut -c1-120; break; fi
  sleep 5
done
[[ "${out:-}" == *"(mlx)"* ]] || { echo "Not ready after 30 min; see ~/Library/Application Support/Verdict/worker.log. Previous app kept at ${PREVIOUS:-none}" >&2; exit 1; }
# Ready: the previous app is no longer needed as a rollback.
[[ -z "$PREVIOUS" ]] || rm -rf "$PREVIOUS"
