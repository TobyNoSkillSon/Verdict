#!/usr/bin/env bash
# Prebuilt release installer (the default path of scripts/install.sh).
# Usage: install-release.sh VERSION [--dry-run]
set -euo pipefail
VERSION="${1:-${VERDICT_VERSION:-}}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo 'Pass a release version, e.g. 0.1.0' >&2; exit 2; }
DRY_RUN=0
[[ "${2:-}" == '--dry-run' ]] && DRY_RUN=1
[[ $# -le 2 && ( $# -lt 2 || "$DRY_RUN" == 1 ) ]] || { echo 'Usage: install-release.sh VERSION [--dry-run]' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Verdict requires Apple Silicon' >&2; exit 1; }
OS="$(sw_vers -productVersion)"
[[ "${OS%%.*}" -ge 14 ]] || { echo "Verdict requires macOS 14 or newer ($OS)" >&2; exit 1; }
STATUS_FILE="$HOME/Library/Application Support/Verdict/status.json"
if pgrep -xq Verdict && [[ -f "$STATUS_FILE" ]] && ! python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1])).get("loading") else 0)' "$STATUS_FILE"; then
  echo 'Verdict is loading a model. Try again in a moment; installation left unchanged.' >&2; exit 1
fi
BASE="${VERDICT_RELEASE_BASE_URL:-https://github.com/TobyNoSkillSon/Verdict/releases/download/v$VERSION}"
[[ "$BASE" == https://* ]] || { echo 'Release base URL must use HTTPS' >&2; exit 1; }
ZIP="Verdict-$VERSION-arm64.zip"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/verdict-release.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE/$ZIP" -o "$TEMP/$ZIP"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE/SHA256SUMS" -o "$TEMP/SHA256SUMS"
EXPECTED="$(awk -v name="$ZIP" '$2 == name { print $1 }' "$TEMP/SHA256SUMS")"
[[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Missing or ambiguous SHA-256 for $ZIP" >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$TEMP/$ZIP" | awk '{print $1}')"
[[ "$(printf '%s' "$ACTUAL" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')" ]] || {
  echo "SHA-256 mismatch for $ZIP" >&2; exit 1
}
echo "Verified SHA-256: $ACTUAL  $ZIP"
mkdir "$TEMP/unpacked"
ditto -x -k "$TEMP/$ZIP" "$TEMP/unpacked"
APP="$TEMP/unpacked/Verdict.app"
[[ -x "$APP/Contents/MacOS/Verdict" && -x "$APP/Contents/MacOS/verdict-helper" && -s "$APP/Contents/Resources/mlx.metallib" ]] || {
  echo 'Release archive lacks the native app, helper, or Metal library' >&2; exit 1;
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || {
  echo 'Version in app does not match archive name' >&2; exit 1;
}
codesign --verify --deep --strict "$APP"
# The hash detects corruption; a checksum fetched from the same release is not a signature.
if [[ "$DRY_RUN" == 1 ]]; then echo 'Dry run complete; nothing installed'; exit 0; fi

DEST=/Applications
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
# Quit a running Verdict only when it is not loading a model (unattended updates, never mid-load).
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
STAGED="$DEST/.Verdict.app.install.$$"
[[ ! -e "$STAGED" ]] || { echo "Staging path exists: $STAGED" >&2; exit 1; }
ditto "$APP" "$STAGED"
codesign --verify --deep --strict "$STAGED"
PREVIOUS=''
if [[ -e "$DEST/Verdict.app" ]]; then
  PREVIOUS="$DEST/.Verdict.app.previous.$(date +%Y%m%d%H%M%S).$$"
  mv "$DEST/Verdict.app" "$PREVIOUS"
fi
if ! mv "$STAGED" "$DEST/Verdict.app"; then
  [[ -z "$PREVIOUS" ]] || mv "$PREVIOUS" "$DEST/Verdict.app"
  echo 'Install failed; previous app restored' >&2; exit 1
fi
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/verdict"
install -m 644 "$DEST/Verdict.app/Contents/Resources/verdict.py" "$HOME/.local/share/verdict/verdict.py"
printf '%s\n' "$DEST/Verdict.app" > "$HOME/.local/share/verdict/app-path"
# Keep the unchanged Python client pointed at the installed app even when the
# writable destination was ~/Applications rather than /Applications.
cat > "$HOME/.local/bin/verdict" <<'SH'
#!/bin/sh
VERDICT_APP="$(cat "$HOME/.local/share/verdict/app-path")"
export VERDICT_APP
exec python3 "$HOME/.local/share/verdict/verdict.py" "$@"
SH
chmod 755 "$HOME/.local/bin/verdict"
echo "installed $DEST/Verdict.app, CLI ~/.local/bin/verdict"
open -g "$DEST/Verdict.app"
echo "starting (first run downloads Laya English, ~0.8 GB)…"
export VERDICT_APP="$DEST/Verdict.app"
for _ in $(seq 1 360); do
  out="$("$HOME/.local/bin/verdict" status 2>/dev/null || true)"
  if [[ "$out" == *"(mlx)"* ]]; then echo "ready: $out" | cut -c1-120; break; fi
  sleep 5
done
[[ "${out:-}" == *"(mlx)"* ]] || { echo "not ready after 30 min; see ~/Library/Application Support/Verdict/worker.log. Previous app kept at ${PREVIOUS:-none}" >&2; exit 1; }
[[ -z "$PREVIOUS" ]] || rm -rf "$PREVIOUS"
echo "next: 'verdict skill' prints the agent skill; install it into your harness"
