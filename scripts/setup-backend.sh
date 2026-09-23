#!/bin/bash
# Creates the isolated Python runtime for the Verdict worker. No model downloads here.
set -euo pipefail
ROOT="${VERDICT_SUPPORT_DIR:-$HOME/Library/Application Support/Verdict}"
PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c 'import sys; assert (3,12) <= sys.version_info[:2] < (3,15)' 2>/dev/null; then
  echo 'Python 3.12–3.14 is required (brew install python@3.12), or set PYTHON=/path/to/python3.' >&2; exit 1
fi
"$PYTHON" -c 'import platform; assert platform.system()=="Darwin" and platform.machine()=="arm64", "Apple Silicon macOS required"'
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCK="$HERE/../Resources/runtime-requirements.txt"
[[ -f "$LOCK" ]] || LOCK="$HERE/runtime-requirements.txt"
HASH="$("$PYTHON" -c 'import hashlib,pathlib,sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()[:12])' "$LOCK")"
PYVER="$("$PYTHON" -c 'import sys; print("%s.%s" % sys.version_info[:2])')"
TARGET="$ROOT/Runtimes/laya-$HASH-python-$PYVER"
umask 077
mkdir -p "$ROOT/Runtimes"
if [[ ! -f "$TARGET/.verdict-ready" ]]; then
  "$PYTHON" -m venv "$TARGET"
  "$TARGET/bin/python" -m pip install --quiet --upgrade pip
  "$TARGET/bin/python" -m pip install --quiet -r "$LOCK"
  "$TARGET/bin/python" -c "import laya_mlx, mlx.core"
  touch "$TARGET/.verdict-ready"
fi
ln -sfn "$TARGET" "$ROOT/runtime"
"$PYTHON" - "$ROOT" "$TARGET" <<'PY'
import json, pathlib, sys
root, target = map(pathlib.Path, sys.argv[1:3])
cfg = root / 'config.json'
data = json.loads(cfg.read_text()) if cfg.exists() else {"hotModels": ["laya-english"], "launchAtLogin": False}
data['executable'] = str(target / 'bin/python')
cfg.write_text(json.dumps(data, indent=2, sort_keys=True))
print('Runtime ready:', target)
PY
