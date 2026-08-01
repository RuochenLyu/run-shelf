# Plan 004: Project one cross-process live-run state

> **Executor instructions:** Claims remain the cross-process fact source. Do not
> add a second writable status registry or weaken process-identity checks.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- RunShelf/Core/Runner/TaskRunClaim.swift RunShelf/Core/Storage/DiskScan.swift RunShelf/Core/Stores/TaskStore.swift RunShelf/App/Views/ContentView.swift RunShelf/App/Views/LogContentLoader.swift RunShelf/App/Views/LogView.swift RunShelf/RunShelfApp.swift RunShelfTests`

## Status

- **Priority:** P1
- **Effort:** L
- **Risk:** MED
- **Depends on:** Plans 001 and 002
- **Category:** bug, architecture, performance
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

App, CLI, and Scheduler share claims on disk, but the UI currently reports only
App-local runs. Closing the main window also stops disk polling, and selected log
files do not refresh while growing. A single live projection is required for the
menu bar, sidebar, task header, run gating, and logs to tell the truth.

## Current state

- `TaskStore.runningTaskIDs` and `runningStartedAt` are fed by local cancellation
  dictionaries at `TaskStore.swift:403-431`.
- `TaskRunClaimManager.activeClaims` already performs shared claim validation.
- `ContentView.swift:40-46` owns the only 15-second refresh loop; its first refresh
  occurs after sleeping and it dies with the window.
- `LogContentLoader.load` skips forever when the same key has non-nil `loadTask`
  at lines 35-39; completion does not clear that task.
- `LogView` reloads only when run ID or task ID changes at lines 23-25.
- `TaskStore.refreshRuns` synchronously calls `diskLoader.loadRuns` on MainActor
  at `TaskStore.swift:603-606`.

## Target structure

- `TaskLiveActivity`: pure Sendable value containing validated active claims,
  earliest start, run IDs, and hosts for one task.
- `TaskDiskMonitor`: app-lifetime, immediate + periodic detached scans, coalesced
  refresh requests, injectable interval/clock.
- `TaskRunCoordinator`: owns only App-local cancellation handles; it is not the
  authority for whether a task is running.
- `TaskStore`: remains the SwiftUI facade and merges local just-started state with
  disk-projected activity until the first claim scan observes it.

## Scope

**In scope:** claim projection, disk scan result, TaskStore runtime fields,
app-lifetime monitoring, sidebar/header/menu consumers, log loader/view, focused
tests, and minimal new Core/App service files.

**Out of scope:** Task CRUD/CAS rewrites, database/index creation, changing claim
format, adding unverified `kill()` calls to UI, and full TaskStore decomposition.

## Steps

### 1. Characterize live projection and refresh coalescing

Add tests for external `cli`/`scheduler` claims appearing and disappearing,
stale claims being excluded, `concurrency=allow` with multiple claims, earliest
start selection, immediate first refresh, and a refresh requested during a scan
causing exactly one follow-up scan.

**Verify:** tests fail against local-only state and window-owned polling.

### 2. Return validated activity from detached disk scans

Extend `DiskScanResult` with a strongly typed activity map produced using
`TaskRunClaimManager.activeClaims`. Do not duplicate PID/start-time validation.
Apply the value map on MainActor alongside task/run entries.

**Verify:** external and local hosts produce the same `isRunning` UI projection;
stale claims do not.

### 3. Separate activity from cancellation capability

Derive `runningTaskIDs`, `runningStartedAt`, sorting, menu pulse, and run/delete
gating from projected activities plus the local claim-visibility bridge. Add
`canCancelTask(id:)`: local cancellation handles remain supported. For external
runs, either call a future shared Core cancel service or disable Stop with an
accurate host explanation; do not copy CLI signal code into a View or Store.

**Verify:** `allow` stays running until its final claim disappears; external runs
are shown but never terminated through an unsafe path.

### 4. Move monitoring to App lifetime

Start an idempotent `TaskDiskMonitor` when the App-level store is created, perform
an immediate scan, then periodic scans. Remove the loop from `ContentView`.
Closing/reopening the window must not affect monitoring. Inject timing so tests
do not sleep 15 seconds.

**Verify:** a claim created while the window is closed updates MenuBarExtra; a
reopened window already has current state.

### 5. Remove synchronous full-history reads from MainActor

Manual-run completion and revert must request an asynchronous monitor refresh.
MainActor may merge completed values but must not call `loadRuns` directly.
Preserve definitions and current draft state while run-only results arrive.

**Verify:** `rg -n 'loadRuns\(' RunShelf/Core/Stores` finds no synchronous
TaskStore call; all existing generation/runs-only tests pass.

### 6. Refresh selected live logs safely

Make `LogContentLoader` clear its task on completion/cancel and support explicit
same-key reload. Use file size/mtime signatures to avoid redundant Text layout.
While the selected run has an active claim, poll at a short injected interval;
on transition to terminal, force one final load and stop. Cancel when selection
or view lifetime changes. Retain current key checks and 1 MiB tail behavior.

**Verify:** appended output appears without switching runs; terminal output is
loaded once; selection changes cannot receive stale content.

## Test plan

- Core projection tests for host, stale claim, multiple claims, and disappearance.
- Store tests for local-to-disk bridge and overlapping refresh requests.
- Log reader/loader tests for append, terminal refresh, cancellation, UTF-8, 1 MiB
  tail, and long-line truncation.
- App smoke test: menu state changes while main window is closed.

## Commands and done criteria

- Run project sync, full Xcode tests, and `git diff --check` from Plan 001.
- [ ] App, CLI, and Scheduler claims share one visible state.
- [ ] Main-window lifecycle does not own monitoring.
- [ ] MainActor does no full-history filesystem read.
- [ ] Growing logs and final output refresh without selection changes.
- [ ] No new writable run-state file or unsafe signal path exists.

## STOP conditions

- Implementation bypasses `TaskRunClaimManager` identity validation.
- Accurate display requires changing claim format without a migration plan.
- UI cancellation requires copied/raw `kill()` logic rather than shared Core API.
- Changes spread into CRUD, CAS, schema, or task-format behavior.
- Polling creates concurrent scans or drops the final requested refresh.

## Maintenance notes

Future notification and cross-process cancellation work should consume
`TaskLiveActivity`; it must not introduce a parallel running-state cache.
