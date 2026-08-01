#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Version must look like 1.2.3, got: ${VERSION:-<empty>}" >&2
  exit 64
fi
VERSION_MAJOR="${BASH_REMATCH[1]}"
VERSION_MINOR="${BASH_REMATCH[2]}"
VERSION_PATCH="${BASH_REMATCH[3]}"
if (( 10#$VERSION_MINOR > 999 || 10#$VERSION_PATCH > 999 )); then
  echo "Minor and patch versions must be <= 999." >&2
  exit 64
fi
BUNDLE_BUILD_NUMBER="$((10#$VERSION_MAJOR * 1000000 + 10#$VERSION_MINOR * 1000 + 10#$VERSION_PATCH))"

if [[ -f "$ROOT_DIR/.release.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT_DIR/.release.env"
  set +a
fi

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
SKIP_NOTARY="${RUN_SHELF_SKIP_NOTARY:-0}"
if [[ "$SKIP_NOTARY" == "1" ]]; then
  NOTARY_PROFILE=""
fi
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

if [[ -z "$NOTARY_PROFILE" && "$SKIP_NOTARY" != "1" ]]; then
  echo "RUN_SHELF_NOTARY_PROFILE is required for release packaging." >&2
  echo "For local signed-only packaging, set RUN_SHELF_SKIP_NOTARY=1 explicitly." >&2
  exit 64
fi

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED_DATA" "$DIST_DIR"/*

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/check.sh"

xcodebuild -quiet build \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUNDLE_BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at $APP_PATH" >&2
  exit 1
fi

BUILT_MARKETING_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
BUILT_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
if [[ "$BUILT_MARKETING_VERSION" != "$VERSION" || "$BUILT_BUILD_NUMBER" != "$BUNDLE_BUILD_NUMBER" ]]; then
  echo "Bundle version mismatch: expected $VERSION ($BUNDLE_BUILD_NUMBER), got $BUILT_MARKETING_VERSION ($BUILT_BUILD_NUMBER)" >&2
  exit 65
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
  echo "RUN_SHELF_SKIP_NOTARY=1; produced artifacts will be signed but not notarized." >&2
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
