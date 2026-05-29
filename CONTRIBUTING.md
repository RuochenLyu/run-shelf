# Contributing

Run Shelf is a small native macOS project. Keep changes local-first, file-format compatible, and easy to inspect.

## Development Setup

```bash
gem install xcodeproj
ruby scripts/generate_xcodeproj.rb
```

Build and test before sending changes:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## Project Rules

- Keep task data readable on disk.
- Preserve `schemaVersion` compatibility unless the migration path is included.
- Keep background scheduling observable through files and logs.
- Do not add telemetry or network sync without a product decision and documentation update.
- Put macOS 26-only APIs behind `#available(macOS 26, *)` and keep the macOS 15 path working.
