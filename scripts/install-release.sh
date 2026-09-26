#!/usr/bin/env bash
# Prebuilt release installer (the default path of scripts/install.sh).
# Usage: install-release.sh VERSION [--dry-run]
# Overrides (tests; defaults in brackets): VERDICT_RELEASE_BASE_URL [the GitHub release, HTTPS only],
# VERDICT_INSTALL_DIR [/Applications, else ~/Applications], VERDICT_SUPPORT_DIR [~/Library/Application Support/Verdict].
# Only the Verdict.app in the install directory is quit and replaced; another copy running elsewhere is left alone.
set -euo pipefail
VERSION="${1:-${VERDICT_VERSION:-}}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo 'Pass a release version, e.g. 0.1.0' >&2; exit 2; }
DRY_RUN=0
[[ "${2:-}" == '--dry-run' ]] && DRY_RUN=1
[[ $# -le 2 && ( $# -lt 2 || "$DRY_RUN" == 1 ) ]] || { echo 'Usage: install-release.sh VERSION [--dry-run]' >&2; exit 2; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Verdict requires Apple Silicon' >&2; exit 1; }
OS="$(sw_vers -productVersion)"
[[ "${OS%%.*}" -ge 14 ]] || { echo "Verdict requires macOS 14 or newer ($OS)" >&2; exit 1; }
SUPPORT="${VERDICT_SUPPORT_DIR:-$HOME/Library/Application Support/Verdict}"
STATUS_FILE="$SUPPORT/status.json"
if [[ -n "${VERDICT_INSTALL_DIR:-}" ]]; then DEST="$VERDICT_INSTALL_DIR"
else DEST=/Applications; [[ -w "$DEST" ]] || DEST="$HOME/Applications"; fi
# The Verdict processes running this install's app (by executable path; LaunchServices starts it with its full path).
running_app() {
  local exe; exe="$(cd "$DEST" 2>/dev/null && pwd -P)/Verdict.app/Contents/MacOS/Verdict" || return 0
  ps -axww -o pid=,comm= | awk -v exe="$exe" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe) print pid }'
}
not_loading() { [[ ! -f "$STATUS_FILE" ]] || python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1])).get("loading") else 0)' "$STATUS_FILE"; }
if [[ -n "$(running_app)" ]] && ! not_loading; then
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

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
# Quit the running Verdict only when it is not loading a model (unattended updates, never mid-load). SIGTERM quits
# Verdict like its Quit item; an earlier Verdict exits at once and its worker follows (its stdin closes).
PIDS="$(running_app)"
if [[ -n "$PIDS" ]]; then
  not_loading || { echo 'Verdict is loading a model. Try again in a moment; installation left unchanged.' >&2; exit 1; }
  kill -TERM $PIDS 2>/dev/null || true
  for _ in $(seq 1 100); do [[ -z "$(running_app)" ]] && break; sleep 0.2; done
  [[ -z "$(running_app)" ]] || { echo 'Verdict did not quit; installation left unchanged.' >&2; exit 1; }
fi
STAGED="$DEST/.Verdict.app.install.$$"
[[ ! -e "$STAGED" ]] || { echo "Staging path exists: $STAGED" >&2; exit 1; }
ditto "$APP" "$STAGED"
xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true   # never install it quarantined (curl sets none)
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
rm -f "$HOME/.local/bin/verdict"
if [[ -x "$DEST/Verdict.app/Contents/Helpers/verdict" ]]; then
  ln -s "$DEST/Verdict.app/Contents/Helpers/verdict" "$HOME/.local/bin/verdict"
else
  # Releases before the Swift CLI: their verdict.py is the command line.
  cat > "$HOME/.local/bin/verdict" <<'SH'
#!/bin/sh
VERDICT_APP="$(cat "$HOME/.local/share/verdict/app-path")"
export VERDICT_APP
exec python3 "$HOME/.local/share/verdict/verdict.py" "$@"
SH
  chmod 755 "$HOME/.local/bin/verdict"
fi
echo "installed $DEST/Verdict.app, CLI ~/.local/bin/verdict"
# -n: a new instance even when another copy of Verdict runs; open does not pass the environment on, so VERDICT_*
# settings (an isolated test instance) are passed explicitly.
OPEN_ENV=()
while IFS= read -r name; do OPEN_ENV+=(--env "$name=${!name}"); done < <(compgen -e | grep '^VERDICT_' || true)
open -n -g ${OPEN_ENV[@]+"${OPEN_ENV[@]}"} "$DEST/Verdict.app"
echo "starting…"
export VERDICT_APP="$DEST/Verdict.app"
ready_check() {  # this version's helper answering and not loading; a model loaded, or none in the launch set (a fresh install has none)
  python3 - "$SUPPORT" "$VERSION" <<'PYEOF' 2>/dev/null
import json, sys, urllib.request
d = sys.argv[1]
try:
    s = json.load(open(d + '/status.json'))
    with urllib.request.urlopen(f"http://127.0.0.1:{s['port']}/status", timeout=5) as r: s = json.load(r)
except Exception:
    sys.exit(1)
if len(sys.argv) > 2 and 'version' in s and s['version'] != sys.argv[2]:
    sys.exit(1)                 # still the replaced version's worker
try:
    hot = json.load(open(d + '/config.json')).get('hotModels', [])
except FileNotFoundError:
    hot = []                    # the app writes config.json on the first change; until then nothing is loaded at launch
except Exception:
    sys.exit(1)
sys.exit(0 if not s.get('loading') and (s.get('models') or not hot) else 1)
PYEOF
}
ready=0
for _ in $(seq 1 360); do
  if ready_check; then ready=1; echo "ready: $("$HOME/.local/bin/verdict" status 2>/dev/null)" | cut -c1-120; break; fi
  sleep 5
done
[[ "$ready" == 1 ]] || { echo "not ready after 30 min; see $SUPPORT/worker.log. Previous app kept at ${PREVIOUS:-none}" >&2; exit 1; }
[[ -z "$PREVIOUS" ]] || rm -rf "$PREVIOUS"
echo "next: 'verdict skill' prints the agent skill; install it into your harness"
