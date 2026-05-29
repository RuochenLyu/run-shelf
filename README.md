# Run Shelf

Run Shelf is a local-first macOS app for creating, scheduling, running, and inspecting Shell automation tasks.

It is designed for personal developer workflows: recurring scripts, local health checks, maintenance jobs, and small automation snippets that should stay readable on disk.

## Features

- File-based task model: each task is a folder with `task.json`, `run.sh`, `notes.md`, and run history.
- Built-in task templates for common local automation jobs.
- Native Shell editor with lightweight syntax highlighting and dangerous-command warnings.
- Manual runs with stdout/stderr history, script snapshots, exit status, timeout handling, and cancellation.
- Five-field cron schedules with preview and missed-run handling.
- Background scheduler helper managed through `SMAppService`.
- Failure notifications and retention cleanup.
- Local-first storage. Run Shelf does not upload task definitions, scripts, logs, or run history.

## Requirements

```text
macOS 15 or later
Xcode 26 or later for source builds
Ruby + xcodeproj gem for regenerating the Xcode project
```

Run Shelf targets macOS 15+. On macOS 26, the app uses the system's current native visual treatment where available. macOS 15 and 16 keep the same core functionality with the native controls available on those systems.

## Install

Download the latest release from GitHub, unzip `RunShelf-<version>-macOS15.zip`, and move `Run Shelf.app` to `/Applications`.

The background scheduler is optional. Enable it inside the app settings after first launch.

## Build From Source

Install the project generator dependency:

```bash
gem install xcodeproj
```

Regenerate the Xcode project when files are added or removed:

```bash
ruby scripts/generate_xcodeproj.rb
```

Build from the command line:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project RunShelf.xcodeproj \
  -scheme RunShelf \
  -configuration Debug \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Launch a local debug build:

```bash
open ".build/DerivedData/Build/Products/Debug/Run Shelf.app"
```

## Release Builds

Release packaging requires a local Developer ID Application certificate:

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
scripts/package_release.sh 1.0.0
```

To notarize the zip, provide a notarytool keychain profile:

```bash
RUN_SHELF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
RUN_SHELF_NOTARY_PROFILE="your-notary-profile" \
scripts/package_release.sh 1.0.0
```

Release artifacts are written to `.build/release/RunShelf-<version>/`.

See [docs/release.md](docs/release.md) for the full release checklist.

## Data Layout

Task data is stored under:

```text
~/Library/Application Support/Run Shelf/tasks/
```

Scheduler state is stored under:

```text
~/Library/Application Support/Run Shelf/scheduler-state.json
~/Library/Application Support/Run Shelf/scheduler-heartbeat.json
~/Library/Application Support/Run Shelf/scheduler.log
```

Each task directory contains:

```text
task.json
run.sh
notes.md
runs/<run-id>/meta.json
runs/<run-id>/stdout.log
runs/<run-id>/stderr.log
runs/<run-id>/run.sh.snapshot
```

## Background Scheduler

The app embeds a helper executable:

```text
Run Shelf.app/Contents/Library/Helpers/RunShelfScheduler
```

It also embeds the `SMAppService` LaunchAgent plist:

```text
Run Shelf.app/Contents/Library/LaunchAgents/com.aix4u.runshelf.scheduler.plist
```

When enabled, the scheduler checks tasks every 30 seconds, matches five-field cron expressions at minute granularity, records stale runs that missed their allowed delay window, and writes heartbeat state for the app to inspect.

## Project Docs

- [docs/requirements.md](docs/requirements.md): product and implementation requirements.
- [docs/roadmap.md](docs/roadmap.md): development roadmap and deferred work.
- [docs/release.md](docs/release.md): release checklist and packaging flow.

## License

Run Shelf is released under the MIT License. See [LICENSE](LICENSE).
