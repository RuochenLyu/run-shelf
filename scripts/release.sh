#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/release.sh <version> --notes-file <path>

Example:
  scripts/release.sh 1.1.2 --notes-file /tmp/runshelf-1.1.2-notes.md
USAGE
}

VERSION="${1:-}"
if [[ "$VERSION" == "-h" || "$VERSION" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$VERSION" || "$VERSION" == -* ]]; then
  usage
  exit 64
fi
shift

NOTES_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must look like 1.2.3, got: $VERSION" >&2
  exit 64
fi

if [[ -z "$NOTES_FILE" || ! -f "$NOTES_FILE" ]]; then
  echo "--notes-file is required and must point to an existing file." >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$ROOT_DIR/.release.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT_DIR/.release.env"
  set +a
fi

TAG="v$VERSION"
DIST_DIR="$ROOT_DIR/.build/release/RunShelf-$VERSION"
DMG_PATH="$DIST_DIR/RunShelf-$VERSION-macOS15.dmg"
ZIP_PATH="$DIST_DIR/RunShelf-$VERSION-macOS15.zip"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash changes before releasing." >&2
  git status --short >&2
  exit 65
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Local tag already exists: $TAG" >&2
  exit 65
fi

if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "Remote tag already exists: $TAG" >&2
  exit 65
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub release already exists: $TAG" >&2
  exit 65
fi

gh auth status >/dev/null

"$ROOT_DIR/scripts/package_release.sh" "$VERSION"

xcrun stapler validate "$ROOT_DIR/.build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if unzip -l "$ZIP_PATH" | rg '(^|/)\._|__MACOSX'; then
  echo "ZIP contains macOS resource-fork noise." >&2
  exit 65
fi

plutil -extract BundleProgram raw \
  "$ROOT_DIR/.build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app/Contents/Library/LaunchAgents/com.aix4u.runshelf.scheduler.plist" |
  rg -qx 'Contents/Library/LaunchServices/RunShelfScheduler'

git tag -a "$TAG" -m "Run Shelf $VERSION"
git push origin main
git push origin "$TAG"

gh release create "$TAG" \
  "$DMG_PATH" \
  "$DMG_PATH.sha256" \
  "$ZIP_PATH" \
  "$ZIP_PATH.sha256" \
  --title "Run Shelf $VERSION" \
  --notes-file "$NOTES_FILE"

gh release view "$TAG" --json tagName,name,publishedAt,url,assets
