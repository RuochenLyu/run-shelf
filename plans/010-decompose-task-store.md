# Plan 010: Decompose TaskStore behind stable UI APIs

> **Executor instructions:** This is a behavior-preserving refactor after Plans
> 001–009. If characterization tests are incomplete or public Store semantics need
> to change, STOP and split that behavior into a separate plan.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- RunShelf/Core/Stores/TaskStore.swift RunShelf/Core/Storage RunShelf/Core/Runner RunShelf/App RunShelfTests`
> Before execution, replace `a463de3` with the commit containing Plans 001–009 and
> refresh every current-state excerpt; otherwise this plan is stale by design.

## Status

- **Priority:** P2
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** Plans 004, 005, 007, and 008
- **Category:** tech debt, architecture
- **Planned at:** initial audit commit `a463de3`, 2026-07-12; refresh required

## Why this matters

`TaskStore` is a roughly 633-line MainActor object combining UI selection,
drafts, validation, repository mutations, disk scanning, run execution,
cancellation, history, errors, Finder, and seeding. Adding live projection and
bounded queries without extraction will make concurrency invariants harder to
review. This refactor should occur only after behavior is tested and corrected.

## Expected preconditions after earlier plans

- Definition mutation and CAS live in `TaskRepository` with stable locks.
- App-lifetime scanning lives in `TaskDiskMonitor` and returns value snapshots.
- App-local cancellation lives in `TaskRunCoordinator`.
- History/log reads are bounded and asynchronous.
- App and Core characterization tests run under `scripts/check.sh`.

If these names differ, map by responsibility rather than forcing new duplicate
types. Do not create abstractions that already exist after prior execution.

## Target responsibilities

1. `TaskStore`: SwiftUI facade, published view state, selection, draft commands,
   and translation of domain errors into existing UI messages.
2. `TaskRepository`: task definition CRUD, revision, slug, and lock invariants.
3. `TaskDiskMonitor`: scan lifecycle, coalescing, signatures, runs/activity values.
4. `TaskRunCoordinator`: start/cancel orchestration and local cancellation handles.
5. Optional `TaskSelectionState`: only if extraction removes substantial logic;
   do not create a one-method wrapper.

## Scope

**In scope:** `TaskStore.swift`, already-introduced monitor/coordinator types,
their tests, dependency injection seams, and View call-site adjustments needed to
preserve the existing public behavior.

**Out of scope:** new features, file/schema changes, UI redesign, renamed user
copy, changing concurrency/schedule semantics, new persistence layers, and release
workflows.

## Steps

### 1. Freeze the public behavior

Inventory every View access to TaskStore and add characterization tests for
selection changes, dirty drafts, save/revert/conflict, create/delete, run/cancel,
sorting, error presentation, and scan merge. Record the intended public facade;
do not expose repository/monitor internals directly to Views.

**Verify:** tests pass before moving code and fail if a published state transition
is deliberately perturbed in a temporary local experiment.

### 2. Inject existing collaborators

Replace concrete construction inside TaskStore with initializer-injected protocol
or concrete collaborators only where tests and production already need variants.
Keep a zero-argument convenience initializer for App composition. Avoid protocol
abstraction for types with one fixed implementation unless a test seam requires it.

**Verify:** production App starts identically; tests use temporary repositories,
fake clocks, and deterministic monitors without real user state.

### 3. Move scan lifecycle and caches as one unit

Move refresh state, signature/runs caches, generations, pending refresh, detached
scan launch, and result application ownership into `TaskDiskMonitor` or a single
scan state type. Preserve dirty-task and generation invariants; TaskStore receives
immutable results/callbacks and publishes merged state.

**Verify:** all DiskScanner/dirty CAS/live activity tests remain green and no
duplicate signature cache exists.

### 4. Move run orchestration as one unit

Move local cancellation maps, run start timestamps, TaskRunner detached execution,
and completion callbacks into `TaskRunCoordinator`. TaskStore retains command
methods used by Views and publishes activity values supplied by Plan 004.

**Verify:** local/external runs, allow/skip, cancel, failure notification, and final
refresh tests remain green.

### 5. Remove duplicate storage helpers

Delete TaskStore wrappers/read helpers that duplicate `TaskRepository` or
`TaskFileStore`, including any remaining swallowing `readText`. All definition
writes must preserve revision/lock semantics from Plans 001–002.

**Verify:** `rg -n 'String\(contentsOf:|TaskFileSignature|loadRuns\(' RunShelf/Core/Stores`
shows only deliberate facade-free references; no duplicated repository logic.

### 6. Reduce View coupling without API churn

Keep current command/query names when sound. Replace only direct access to fields
that no longer belong in TaskStore with narrow computed facade properties. Do not
make Views coordinate locks, disk scans, claims, or FileManager.

**Verify:** App/UI tests from Plan 007 pass unchanged or with selector-only updates.

## Commands and done criteria

- `scripts/check.sh` after every extraction step → exit 0.
- `git diff --check` → no output.
- [ ] TaskStore contains no direct filesystem enumeration or detached scan body.
- [ ] One owner exists for scan caches and one for local cancellation handles.
- [ ] Views depend only on the stable facade, never repository/lock details.
- [ ] No task file, JSON payload, scheduling, or user-visible behavior changes.
- [ ] Commits are split by extraction unit and each is independently green.

## STOP conditions

- Earlier plans are not complete or this plan's refreshed baseline is unavailable.
- A failing characterization test reveals an unresolved behavior decision.
- Extraction requires changing file, schema, claim, or UI contract.
- Two collaborators end up owning the same cache/state or call each other cyclically.
- A step fails `scripts/check.sh` twice after a reasonable correction.

## Maintenance notes

Review for state ownership and actor boundaries, not line-count alone. A smaller
TaskStore with duplicated caches is worse than the original; each invariant must
have exactly one owner.
