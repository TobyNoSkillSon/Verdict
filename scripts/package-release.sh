#!/usr/bin/env bash
# Local release staging only: no installation, account action, or publication.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT/Resources/Info.plist")}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo "Invalid version: $VERSION" >&2; exit 2; }
OUT="${VERDICT_RELEASE_OUTPUT_DIR:-$PROJECT/dist/$VERSION}"
[[ ! -e "$OUT" ]] || { echo "Output already exists; preserving it: $OUT" >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Requires an Apple Silicon Mac' >&2; exit 1; }
mkdir -p "$PROJECT/.build"
STAGE="$(mktemp -d "$PROJECT/.build/.package-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
VERDICT_APP_PATH="$STAGE/Verdict.app" VERDICT_RELEASE_VERSION="$VERSION" "$PROJECT/scripts/build.sh"
APP="$STAGE/Verdict.app"
codesign --verify --deep --strict "$APP"
ZIP="Verdict-$VERSION-arm64.zip"
# No extended attributes in the archive (no ._* entries); the /usr/bin/unzip extraction must verify.
"$PROJECT/scripts/release-zip.sh" "$APP" "$STAGE/$ZIP"
# The archive must carry the licences (Verdict's and every linked package's).
LISTING="$(zipinfo -1 "$STAGE/$ZIP")"
for f in LICENSE NOTICE THIRD_PARTY_NOTICES.txt; do
  grep -qx "Verdict.app/Contents/Resources/$f" <<<"$LISTING" || { echo "Archive is missing Verdict.app/Contents/Resources/$f" >&2; exit 1; }
done
shasum -a 256 "$STAGE/$ZIP" | awk -v zip="$ZIP" '{print $1 "  " zip}' > "$STAGE/SHA256SUMS"
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
mv "$APP" "$OUT/Verdict.app"
mv "$STAGE/$ZIP" "$OUT/$ZIP"
mv "$STAGE/SHA256SUMS" "$OUT/SHA256SUMS"
echo "Packaged locally: $OUT/$ZIP and $OUT/SHA256SUMS (not published or installed)"
