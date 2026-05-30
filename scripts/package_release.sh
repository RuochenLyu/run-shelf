#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.0.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/ReleaseDerivedData"
DIST_ROOT="$ROOT_DIR/.build/release"
DIST_DIR="$DIST_ROOT/RunShelf-$VERSION"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Run Shelf.app"
HELPER_PATH="$APP_PATH/Contents/Library/LaunchServices/RunShelfScheduler"
CLI_PATH="$APP_PATH/Contents/Library/Helpers/runshelf"
ZIP_PATH="$DIST_DIR/RunShelf-$VERSION-macOS15.zip"
DMG_PATH="$DIST_DIR/RunShelf-$VERSION-macOS15.dmg"
ZIP_CHECKSUM_PATH="$ZIP_PATH.sha256"
DMG_CHECKSUM_PATH="$DMG_PATH.sha256"
DMG_STAGE_DIR="$DIST_DIR/dmg-stage"

SIGN_IDENTITY="${RUN_SHELF_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${RUN_SHELF_NOTARY_PROFILE:-}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
export COPYFILE_DISABLE=1

staple_artifact() {
  local artifact_path="$1"
  local attempt

  for attempt in 1 2 3; do
    if xcrun stapler staple "$artifact_path"; then
      return 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
      echo "stapler failed for $artifact_path; retrying in 15 seconds..." >&2
      sleep 15
    fi
  done

  return 1
}

sign_artifact() {
  local artifact_path="$1"
  shift
  local attempt

  for attempt in 1 2 3; do
    if codesign --force --timestamp --sign "$SIGN_IDENTITY" "$@" "$artifact_path"; then
      return 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
      echo "codesign failed for $artifact_path; retrying in 15 seconds..." >&2
      sleep 15
    fi
  done

  return 1
}

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "RUN_SHELF_SIGN_IDENTITY is required, for example:" >&2
  echo "  RUN_SHELF_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" $0 $VERSION" >&2
  exit 64
fi

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED_DATA" "$DIST_DIR"/*

cd "$ROOT_DIR"

xcodebuild -quiet test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath "$ROOT_DIR/.build/TestDerivedData" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild -quiet build \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at $APP_PATH" >&2
  exit 1
fi

sign_artifact "$HELPER_PATH" --options runtime
sign_artifact "$CLI_PATH" --options runtime
sign_artifact "$APP_PATH" --options runtime
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  PRE_NOTARY_ZIP="$DIST_DIR/RunShelf-$VERSION-notary-upload.zip"
  ditto -c -k --keepParent --norsrc --noextattr "$APP_PATH" "$PRE_NOTARY_ZIP"
  xcrun notarytool submit "$PRE_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  staple_artifact "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
  rm -f "$PRE_NOTARY_ZIP"
else
  echo "RUN_SHELF_NOTARY_PROFILE is not set; produced artifacts will be signed but not notarized." >&2
fi

ditto -c -k --keepParent --norsrc --noextattr "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_CHECKSUM_PATH"

rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
ditto --norsrc --noextattr "$APP_PATH" "$DMG_STAGE_DIR/Run Shelf.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"
hdiutil create \
  -volname "Run Shelf $VERSION" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
rm -rf "$DMG_STAGE_DIR"

sign_artifact "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  staple_artifact "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH" > "$DMG_CHECKSUM_PATH"

echo "Release artifacts:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo "Checksums:"
cat "$ZIP_CHECKSUM_PATH"
cat "$DMG_CHECKSUM_PATH"
