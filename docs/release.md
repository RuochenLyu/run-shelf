# Run Shelf Release Checklist

## Support Matrix

```text
Minimum OS: macOS 15
Recommended OS: macOS 26 or later
Distribution: Developer ID signed zip, optionally notarized
Architecture: universal x86_64 + arm64
```

macOS 15 and 16 use the same core feature set with native controls available on those systems. macOS 26-only APIs must be guarded with `#available(macOS 26, *)` and must keep a macOS 15 fallback path.

## Preflight

```bash
git status --short
rg --hidden --pcre2 -n "/Users/|gh[pousr]_[A-Za-z0-9_]+|Developer ID Application: [^(]+ \\([A-Z0-9]{10}\\)" \
  -g '!*.git/**' \
  -g '!.build/**'
```

The search must not find real tokens, local absolute paths, or hardcoded signing identities.

## Test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## Manual Smoke

```text
1. First launch reaches the scheduler permission gate.
2. Enabling background scheduling reaches the main window.
3. Creating a task from a template writes task.json, run.sh, and notes.md.
4. Running a successful script writes stdout.log and a success meta.json.
5. Running a failing script writes stderr.log and a failed meta.json.
6. Stopping a sleep task writes a cancelled meta.json.
7. A scheduled task continues to run after the main window closes.
8. Reopening the app reads scheduler-created history.
```

## Package

The script requires a local Developer ID Application certificate:

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
scripts/package_release.sh 1.0.0
```

To notarize, provide a notarytool keychain profile:

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RUN_SHELF_NOTARY_PROFILE="your-notary-profile" \
scripts/package_release.sh 1.0.0
```

Artifacts:

```text
.build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip
.build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip.sha256
```

## Verify Artifact

```bash
codesign --verify --deep --strict --verbose=2 \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app"

vtool -show-build \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app/Contents/MacOS/Run Shelf"

unzip -l .build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip | \
  rg '(^|/)\\._|__MACOSX' && exit 1 || true
```

If notarized:

```bash
spctl --assess --type execute --verbose=2 \
  ".build/ReleaseDerivedData/Build/Products/Release/Run Shelf.app"
```

## GitHub Release

```bash
git tag v1.0.0
git push origin main v1.0.0
gh release create v1.0.0 \
  .build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip \
  .build/release/RunShelf-1.0.0/RunShelf-1.0.0-macOS15.zip.sha256 \
  --title "Run Shelf 1.0.0" \
  --notes-file CHANGELOG.md
```
