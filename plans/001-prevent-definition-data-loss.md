# Plan 001: Prevent definition data loss

> **Executor instructions:** Follow every step and verification gate. Preserve
> the existing dirty workspace before starting. Do not auto-save, discard drafts,
> or change public task-file formats.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- RunShelf/Editor/ShellScriptEditor.swift RunShelf/Core/Storage/DiskScan.swift RunShelf/Core/Storage/TaskFileStore.swift RunShelf/Core/Stores/TaskStore.swift RunShelfTests`
> This plan was written against uncommitted changes on top of `a463de3`. If the
> live code does not contain the current-state patterns below, STOP and refresh
> the plan before editing.

## Status

- **Priority:** P0
- **Effort:** M
- **Risk:** MED
- **Depends on:** none
- **Category:** bug, tests
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

Three independent paths can destroy task text: the AppKit editor can write to a
previous task after selection changes, disk scans can advance a dirty draft's CAS
baseline and let it overwrite an external edit, and unreadable files are treated
as empty strings. This plan closes those paths without changing the file-native
storage model.

## Current state

- `ShellScriptEditor.updateNSView` updates the NSTextView but not the Coordinator:
  `if textView.string != text { context.coordinator.apply(...) }` at line 45.
- `Coordinator` stores the initial `parent`, and `syncFromTextView` later writes
  `parent.text = textView.string` at line 80.
- `DiskScanner.scan` writes `newSignatures[id] = currentSig` even when
  `known.isDirty` at `DiskScan.swift:200-205`.
- `TaskStore.applyScanResult` adopts every returned signature at
  `TaskStore.swift:230-239`; `saveTask` uses it as `expectedRevision`.
- `TaskFileStore.readText` is `(try? String(contentsOf:encoding:)) ?? ""` at
  `TaskFileStore.swift:174`, so missing, unreadable, directory, and invalid UTF-8
  all collapse to the same value.
- Existing Core tests use temporary task directories and explicit disk writes;
  match `RunShelfTests/RunShelfCoreTests.swift:28-62`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Sync project | `bundle exec ruby scripts/sync_xcodeproj_files.rb` | exit 0 |
| Check sync | `bundle exec ruby scripts/sync_xcodeproj_files.rb --check` | reports in sync |
| Test | `xcodebuild test -project RunShelf.xcodeproj -scheme RunShelf -destination 'platform=macOS' -derivedDataPath .build/TestDerivedData CODE_SIGNING_ALLOWED=NO` | exit 0 |
| Whitespace | `git diff --check` | no output |

## Scope

**In scope:**

- `RunShelf/Editor/ShellScriptEditor.swift`
- `RunShelf/Core/Storage/DiskScan.swift`
- `RunShelf/Core/Storage/TaskFileStore.swift`
- `RunShelf/Core/Stores/TaskStore.swift`
- focused files under `RunShelfTests/`
- `scripts/xcodeproj_sources.rb` and generated pbxproj only if needed to compile
  the editor regression test

**Out of scope:** task lock relocation, slug uniqueness, schema validation,
auto-save behavior, file-format changes, UI redesign, and `TaskStore` refactoring.

## Git workflow

- Branch: `codex/001-prevent-definition-data-loss`
- Use Conventional Commits, for example `fix(storage): prevent stale draft overwrites`.
- Do not push or open a PR unless explicitly instructed.

## Steps

### 1. Add failing regressions first

Add tests for:

1. Reusing the editor Coordinator for binding B after binding A, then simulating
   an NSTextView edit, updates B only.
2. A dirty task whose `run.sh` is externally modified during a scan retains its
   original revision; saving the stale draft returns conflict and leaves the
   external file bytes unchanged.
3. Clean-task signatures still advance and runs-only merges still work.
4. Missing `run.sh` fails; invalid UTF-8 `run.sh` fails; missing `notes.md`
   remains compatible as empty notes; existing but unreadable/invalid notes fail.

If the Editor source is not in the test target, add only the exact Editor files
needed to `scripts/xcodeproj_sources.rb`; do not add the entire App layer.

**Verify:** run the focused tests before fixing → each new regression fails for
the expected reason, not because the fixture cannot build.

### 2. Refresh the editor Coordinator binding

Give Coordinator an internal update method and call it first on every
`updateNSView`. Then compare/apply text. Preserve selection, highlighter
reentrancy protection, undo behavior, and programmatic-update semantics.

**Verify:** editor regression passes; binding A remains byte-for-byte unchanged.

### 3. Preserve the dirty CAS baseline

In the dirty branch of `DiskScanner.scan`, continue producing runs-only changes
and runs cache updates, but do not publish a new definition signature. Ensure
`TaskStore.applyScanResult` preserves the old signature for omitted dirty IDs.
Only revert, successful save, or accepted clean reload may advance the baseline.

**Verify:** external edit + scan + stale App save returns conflict; clean reload
and successful save still refresh the signature.

### 4. Make text reads explicit and throwing

Replace `readText` with required and optional UTF-8 helpers. Optional notes may
return empty only for a confirmed not-found error. All other read/encoding/type
errors must propagate into the existing load issue or save error surfaces. Avoid
`fileExists` followed by a swallowing read as the decision boundary.

**Verify:** all four file cases from Step 1 pass and no valid task changes text.

## Done criteria

- [ ] New editor, dirty-CAS, and text-read regressions pass.
- [ ] A stale dirty save cannot overwrite an external definition change.
- [ ] Missing notes remain backward compatible; unreadable existing files fail.
- [ ] Full test suite, project sync check, and `git diff --check` pass.
- [ ] No source file outside Scope changed.

## STOP conditions

- Existing dirty workspace cannot be reproduced safely in the executor worktree.
- Testing the editor requires importing the whole App lifecycle or SMAppService.
- The proposed fix needs auto-save, draft discard, or a task format migration.
- Any invalid/unreadable existing file is still represented as valid empty text.
- A new regression fails twice for fixture reasons rather than the target behavior.

## Maintenance notes

Reviewers should scrutinize Coordinator reuse and CAS state transitions, not only
the happy-path save. Plan 002 will change lock placement but must preserve the
throwing read and revision semantics established here.
