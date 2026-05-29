#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.0.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/ReleaseDerivedData"
DIST_ROOT="$ROOT_DIR/.build/release"
DIST_DIR="$DIST_ROOT/RunShelf-$VERSION"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Run Shelf.app"
HELPER_PATH="$APP_PATH/Contents/Library/Helpers/RunShelfScheduler"
ZIP_PATH="$DIST_DIR/RunShelf-$VERSION-macOS15.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

SIGN_IDENTITY="${RUN_SHELF_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${RUN_SHELF_NOTARY_PROFILE:-}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
export COPYFILE_DISABLE=1

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "RUN_SHELF_SIGN_IDENTITY is required, for example:" >&2
  echo "  RUN_SHELF_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" $0 $VERSION" >&2
  exit 64
fi

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED_DATA" "$DIST_DIR"/*

cd "$ROOT_DIR"

xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath "$ROOT_DIR/.build/TestDerivedData" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at $APP_PATH" >&2
  exit 1
fi

codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$HELPER_PATH"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  PRE_NOTARY_ZIP="$DIST_DIR/RunShelf-$VERSION-notary-upload.zip"
  ditto -c -k --keepParent --norsrc --noextattr "$APP_PATH" "$PRE_NOTARY_ZIP"
  xcrun notarytool submit "$PRE_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
  rm -f "$PRE_NOTARY_ZIP"
else
  echo "RUN_SHELF_NOTARY_PROFILE is not set; produced zip will be signed but not notarized." >&2
fi

ditto -c -k --keepParent --norsrc --noextattr "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "Release artifact:"
echo "  $ZIP_PATH"
echo "Checksum:"
cat "$CHECKSUM_PATH"
