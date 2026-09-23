#!/bin/bash
# One-shot install for agents and people: build, install the app, start it, wait until a model is hot.
# Prints one short line per step. Safe to rerun (updates in place).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcrun >/dev/null || { echo "Need Apple Command Line Tools: run 'xcode-select --install', then rerun."; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "Verdict needs an Apple Silicon Mac."; exit 1; }
DEST="/Applications"; [[ -w "$DEST" ]] || DEST="$HOME/Applications"; mkdir -p "$DEST"
sw="$(sw_vers -productVersion)"; [[ "${sw%%.*}" -ge 14 ]] || { echo "Verdict needs macOS 14 or newer (this is $sw)."; exit 1; }
echo "preparing Python runtime (first run downloads ~600 MB of packages)…"
scripts/setup-backend.sh >/tmp/verdict-setup.log 2>&1 || { tail -3 /tmp/verdict-setup.log; exit 1; }
echo "building…"
scripts/build.sh >/tmp/verdict-build.log 2>&1 || { tail -5 /tmp/verdict-build.log; exit 1; }
rm -rf "$DEST/Verdict.app" && cp -R dist/Verdict.app "$DEST/"
echo "installed $DEST/Verdict.app, CLI ~/.local/bin/verdict"
open -g "$DEST/Verdict.app"
echo "starting (first run installs a Python runtime and downloads Laya English, ~1 GB)…"
export VERDICT_APP="$DEST/Verdict.app"
for _ in $(seq 1 360); do
  out="$("$HOME/.local/bin/verdict" status 2>/dev/null || true)"
  if [[ "$out" == *"(mlx)"* ]]; then echo "ready: $out" | cut -c1-120; break; fi
  sleep 5
done
[[ "${out:-}" == *"(mlx)"* ]] || { echo "not ready after 30 min; see ~/Library/Application Support/Verdict/worker.log"; exit 1; }
echo "next: 'verdict skill' prints the agent skill; install it into your harness"
