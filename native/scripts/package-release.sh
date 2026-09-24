#!/usr/bin/env bash
# Local release staging only: no installation, account action, or publication.
set -euo pipefail
NATIVE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$(cd "$NATIVE/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT/Resources/Info.plist")}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo "Invalid version: $VERSION" >&2; exit 2; }
OUT="${VERDICT_RELEASE_OUTPUT_DIR:-$NATIVE/dist/$VERSION}"
[[ ! -e "$OUT" ]] || { echo "Output already exists; preserving it: $OUT" >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Requires an Apple Silicon Mac' >&2; exit 1; }
mkdir -p "$NATIVE/.build"
STAGE="$(mktemp -d "$NATIVE/.build/.package-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
VERDICT_APP_PATH="$STAGE/Verdict.app" VERDICT_RELEASE_VERSION="$VERSION" "$PROJECT/scripts/build.sh"
APP="$STAGE/Verdict.app"
codesign --verify --deep --strict "$APP"
ZIP="Verdict-$VERSION-arm64.zip"
ditto -c -k --keepParent "$APP" "$STAGE/$ZIP"
shasum -a 256 "$STAGE/$ZIP" | awk -v zip="$ZIP" '{print $1 "  " zip}' > "$STAGE/SHA256SUMS"
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
mv "$APP" "$OUT/Verdict.app"
mv "$STAGE/$ZIP" "$OUT/$ZIP"
mv "$STAGE/SHA256SUMS" "$OUT/SHA256SUMS"
echo "Packaged locally: $OUT/$ZIP and $OUT/SHA256SUMS (not published or installed)"
