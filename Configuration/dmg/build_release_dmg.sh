#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REQ_FILE="Configuration/dmg/requirements.txt"
# A stable identity keeps the macOS Accessibility grant across updates. Ad hoc signatures ("-")
# are pinned to the cdhash, which changes on every build, so every update would revoke it.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-GravityNotch Code Signing}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-gravitynotch}"
UPDATE_APPCAST=1
RELEASE_TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)
      RELEASE_TAG="${2:?--tag requires a value}"
      shift 2
      ;;
    --no-appcast)
      UPDATE_APPCAST=0
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

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

check_codesign_identity() {
  if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "Warning: ad hoc signing, users will have to grant Accessibility again after this update." >&2
    return 0
  fi
  security find-identity -p codesigning | grep -Fq "\"$CODESIGN_IDENTITY\"" \
    || die "Signing identity \"$CODESIGN_IDENTITY\" not found in the keychain. Import the release .p12, or set CODESIGN_IDENTITY=- to sign ad hoc."
}

cd "$REPO_ROOT"
check_dmgbuild
check_codesign_identity

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

find_sign_update() {
  local local_bin="$REPO_ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  if [ -x "$local_bin" ]; then
    echo "$local_bin"
    return 0
  fi
  if command -v sign_update >/dev/null 2>&1; then
    command -v sign_update
    return 0
  fi
  return 1
}

echo "Signing app bundle (identity: $CODESIGN_IDENTITY)..."
codesign --force --deep -s "$CODESIGN_IDENTITY" "$STAGED_APP"

echo "Packaging $DMG_OUTPUT..."
"$SCRIPT_DIR/create_dmg.sh" "$STAGED_APP" "$DMG_OUTPUT" "GravityNotch"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGED_APP/Contents/Info.plist")"
if [ -z "$RELEASE_TAG" ]; then
  RELEASE_TAG="gravitynotch-v$SHORT_VERSION"
fi
DMG_BYTES="$(stat -f%z "$DMG_OUTPUT")"
DOWNLOAD_URL="https://github.com/adrielakak/GravityNotch/releases/download/$RELEASE_TAG/GravityNotch.dmg"
NOTES_URL="https://github.com/adrielakak/GravityNotch/releases/tag/$RELEASE_TAG"

echo "Release DMG ready: $DMG_OUTPUT (v$SHORT_VERSION / build $BUILD_VERSION, $DMG_BYTES bytes)"

if [ "$UPDATE_APPCAST" -eq 1 ]; then
  if SIGN_UPDATE_BIN="$(find_sign_update)"; then
    ED_SIG="$("$SIGN_UPDATE_BIN" --account "$SPARKLE_KEY_ACCOUNT" -p "$DMG_OUTPUT")"
    python3 "$SCRIPT_DIR/update_appcast.py" \
      --appcast "$REPO_ROOT/docs/appcast.xml" \
      --version "$BUILD_VERSION" \
      --short-version "$SHORT_VERSION" \
      --url "$DOWNLOAD_URL" \
      --length "$DMG_BYTES" \
      --ed-signature "$ED_SIG" \
      --notes-url "$NOTES_URL"
    echo "Updated docs/appcast.xml for $RELEASE_TAG (EdDSA signed with account '$SPARKLE_KEY_ACCOUNT')."
  else
    echo "Warning: Sparkle sign_update binary not found; skipped docs/appcast.xml update." >&2
  fi
fi
