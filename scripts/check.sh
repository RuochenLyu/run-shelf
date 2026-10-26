#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

phase() { echo "==> $1"; }

phase "Bundler dependencies"
bundle check

phase "JSON schemas"
ruby -rjson -e 'ARGV.each { |path| JSON.parse(File.read(path)) }' schemas/*.json

phase "Generated schemas"
bundle exec ruby scripts/generate_cli_schemas.rb --check

phase "Xcode source membership"
bundle exec ruby scripts/sync_xcodeproj_files.rb --check

phase "Script syntax"
for script in scripts/*.rb; do ruby -c "$script" >/dev/null; done
for script in scripts/*.sh; do bash -n "$script"; done

phase "LaunchAgent plist"
plutil -lint RunShelf/Support/com.aix4u.runshelf.scheduler.plist

phase "Tests"
xcodebuild test \
  -only-testing:RunShelfTests/RunShelfCoreTests/testBackgroundPriorityRunsBelowStandard \
  -project RunShelf.xcodeproj \
  -scheme RunShelfTests \
  -destination 'platform=macOS' \
  -derivedDataPath .build/CheckTestDerivedData \
  CODE_SIGNING_ALLOWED=NO

phase "Universal Debug build"
xcodebuild build -quiet \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -destination 'platform=macOS' \
  -derivedDataPath .build/CheckBuildDerivedData \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO

phase "Whitespace"
git diff --check

echo "All checks passed."
