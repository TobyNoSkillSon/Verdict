#!/usr/bin/env bash
# Build the Swift CLI with the stable CLT compiler and MLX shaders with Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$(cd "$ROOT/.." && pwd)"
OUT="${VERDICT_HELPER_OUTPUT_DIR:-$ROOT/.build/release-helper}"
cd "$ROOT"

xcrun metal --version >/dev/null
# SwiftPM's native builder uses the stable Swift 6.3 compiler. Its default
# swiftbuild backend on this host is not equivalent for mlx-swift.
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  /Library/Developer/CommandLineTools/usr/bin/swift build --build-system native -c release
# Xcode compiles the shaders in mlx-swift_Cmlx.bundle; never ship its Swift 6.4 binary.
# This setting is coupled to the pinned mlx-swift core above: both together
# matched the Python oracle across all Laya fixtures; either change alone did not.
xcodebuild -scheme verdict-helper -configuration Release -destination 'platform=macOS' \
  MTL_FAST_MATH=NO \
  -derivedDataPath "$ROOT/.build/xcode" build >/dev/null

BINARY="$ROOT/.build/release/verdict-helper"
METALLIB="$ROOT/.build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
test -f "$BINARY" && test -s "$METALLIB"
file "$BINARY" | grep -q 'Mach-O 64-bit executable arm64'
# The current macOS runtime cannot resolve this Xcode 27 symbol. The smoke
# below catches other unresolved symbols on the build host before packaging.
if nm -u "$BINARY" | grep -Eq '(_swift_initBorrow|_swift_endBorrow)'; then
  echo 'Unsupported Swift runtime borrowing symbol in verdict-helper' >&2; exit 1
fi

mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$BINARY" "$STAGE/verdict-helper"
cp "$METALLIB" "$STAGE/mlx.metallib"
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  /Library/Developer/CommandLineTools/usr/bin/swiftc -parse-as-library -O \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  "$ROOT/scripts/check-helper-ui.swift" -o "$STAGE/check-helper-ui"
VERDICT_HELPER_BINARY="$STAGE/verdict-helper" VERDICT_CATALOG="$PROJECT/Resources/models.json" \
VERDICT_HELPER_UI_CHECK="$STAGE/check-helper-ui" \
python3 - <<'PY'
import json, os, pathlib, re, subprocess, tempfile, urllib.request
with tempfile.TemporaryDirectory(prefix='verdict-helper-smoke-') as support:
    env = dict(os.environ, VERDICT_SUPPORT_DIR=support, HF_HUB_CACHE=support + '/hub',
               VERDICT_STUB_MODELS='1', VERDICT_PRELOAD='', VERDICT_PORT='0')
    process = subprocess.Popen([env['VERDICT_HELPER_BINARY']], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        line = process.stdout.readline()
        if not line: raise RuntimeError('helper exited before port: ' + process.stderr.read()[:800])
        port = json.loads(line)['port']
        base = f'http://127.0.0.1:{port}'
        with urllib.request.urlopen(base + '/status', timeout=8) as response:
            status = json.load(response)
        assert status['pid'] == process.pid and status['port'] == port and status['models'] == {}, status
        assert json.loads((pathlib.Path(support) / 'status.json').read_text())['pid'] == process.pid
        listing = subprocess.check_output(['/usr/bin/lsappinfo', 'list'], text=True, timeout=8)
        assert not re.search(r'\bpid\s*=\s*' + str(process.pid) + r'\b', listing), 'helper registered as a desktop app'
        subprocess.run([env['VERDICT_HELPER_UI_CHECK'], str(process.pid)], check=True, timeout=8)
        with urllib.request.urlopen(urllib.request.Request(base + '/quit', data=b'{}', headers={'Content-Type': 'application/json'}), timeout=8): pass
        process.wait(timeout=8)
        assert process.returncode == 0
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=8)
        process.stdout.close(); process.stderr.close()
PY
# Publish only after all checks; the executable and metallib stay together.
mv -f "$STAGE/verdict-helper" "$OUT/verdict-helper"
mv -f "$STAGE/mlx.metallib" "$OUT/mlx.metallib"
file "$OUT/verdict-helper"
echo "Built $OUT/verdict-helper + mlx.metallib (CLI, /status smoke passed)"
