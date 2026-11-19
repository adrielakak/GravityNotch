#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REQ_FILE="Configuration/dmg/requirements.txt"

die() {
  echo "Error: $*" >&2
  exit 1
}

check_dmgbuild() {
  if command -v dmgbuild >/dev/null 2>&1; then
    return 0
  fi
  local py_scripts
  py_scripts="$(python3 -c 'import sysconfig; print(sysconfig.get_path("scripts") or "")' 2>/dev/null || true)"
  if [ -n "$py_scripts" ] && [ -x "$py_scripts/dmgbuild" ]; then
    export PATH="$py_scripts:$PATH"
    return 0
  fi
  die "dmgbuild is missing. Install it with: python3 -m pip install --require-hashes -r $REQ_FILE"
}

cd "$REPO_ROOT"
check_dmgbuild

if [ ! -f "$SCRIPT_DIR/.background/background.tiff" ]; then
  echo "Generating DMG HiDPI background..."
  python3 "$SCRIPT_DIR/generate_background.py"
fi

BUILD_DIR="$REPO_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGE_DIR="$(mktemp -d /tmp/gravitynotch-stage.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGED_APP="$STAGE_DIR/GravityNotch.app"
DMG_OUTPUT="$BUILD_DIR/GravityNotch.dmg"

mkdir -p "$BUILD_DIR"

echo "Building GravityNotch (Release)..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "$REPO_ROOT/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/Boring Notch.app"
if [ ! -d "$BUILT_APP" ]; then
  BUILT_APP="$DERIVED_DATA/Build/Products/Release/GravityNotch.app"
fi
[ -d "$BUILT_APP" ] || die "Built Release app not found at $BUILT_APP"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
echo "Staging app bundle as GravityNotch.app..."
ditto --norsrc "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"

echo "Applying ad-hoc code signature..."
codesign --force --deep -s - "$STAGED_APP"

echo "Packaging $DMG_OUTPUT..."
"$SCRIPT_DIR/create_dmg.sh" "$STAGED_APP" "$DMG_OUTPUT" "GravityNotch"

echo "Release DMG ready: $DMG_OUTPUT"
