# Plan 005: Bound history, log, and retention I/O

> **Executor instructions:** Keep the filesystem as SSOT. Improve query shape;
> do not introduce a database or silently remove CLI fields.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- RunShelf/Core/Storage/TaskFileStore.swift RunShelf/Core/Storage/TaskRepository.swift RunShelf/Core/Runner/RetentionCleaner.swift RunShelf/Core/Runner/TaskRunner.swift RunShelf/CLI/RunShelfCLI.swift RunShelfTests schemas/cli-result.schema.json docs/agent-usage.md`

## Status

- **Priority:** P1
- **Effort:** L
- **Risk:** MED
- **Depends on:** Plans 002 and 003
- **Category:** performance, bug, security
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

CLI status/log requests currently decode every run of every task, and CLI log
output reads an unbounded file into memory. App paths can also load thousands of
records, while malformed/no-meta run directories escape retention forever. The
repair is directed, bounded filesystem access with explicit truncation metadata.

## Current state

- `TaskFileStore.loadRuns` enumerates, decodes, and sorts every run directory at
  `TaskFileStore.swift:107-125`.
- CLI task list/show use `includeRuns: true` at `RunShelfCLI.swift:90-99`.
- `findRun` loads every task with all runs at `RunShelfCLI.swift:457-471`.
- `readLog` uses `String(contentsOf:)` and returns empty on all errors at lines
  506-515.
- `install-cli --force` does `lstat`, then `FileManager.removeItem` at lines
  280-291, leaving a path replacement window before recursive deletion.
- Retention ignores directories whose meta is missing/invalid at
  `RetentionCleaner.swift:22-30`; TaskRunner creates snapshot/logs before meta at
  `TaskRunner.swift:98-138`.
- Cancel E2E polling can time out and still pass at
  `RunShelfCLIE2ETests.swift:145-159`.

## Scope

**In scope:** bounded/latest/direct run APIs, CLI status/log/list callers and
help/schema payloads, retention orphan handling, safe unlink, cancel E2E cleanup,
Core/CLI tests, Agent docs.

**Out of scope:** global database/index, deleting valid evidence outside policy,
changing run status names/exit codes, changing claim format, and UI live refresh
(Plan 004).

## Steps

### 1. Add directed run-read APIs

Validate run IDs as one safe path component before path construction. Add
`loadRun(taskDirectoryURL:runID:)`, bounded `loadRuns(limit:)`, and
`loadLatestRun`. `findRun` should load task definitions without runs, then check
only the exact run directory/claim per task. Task list/show should preserve the
current `latestRun` payload using latest-only access.

**Verify:** target run lookup is O(task count), not O(all histories), and invalid
run IDs are rejected before filesystem access.

### 2. Make CLI logs bounded and explicit

Default to a 1 MiB tail, matching App protection. Add mutually exclusive
`--full` and `--bytes <N>` with validated limits. Read by seeking with
`FileHandle`, repair a cut UTF-8 prefix, and distinguish empty, missing, and read
failure. Extend JSON payload with `truncated`, `totalBytes`, and `returnedBytes`;
plain output must also disclose truncation.

**Verify:** memory does not scale with total file size in default mode; Chinese
text at the cut boundary remains valid; `--full` is explicit.

### 3. Remove the force-install recursive-delete race

After validating the destination type, use the Darwin unlink syscall for the
single symlink/regular-file entry. Never call recursive `removeItem` on the
user-supplied destination after a separate type check. Preserve refusal for
directories and special files.

**Verify:** regular file and symlink replacement work; directory/special entry
remain untouched; no recursive deletion API is used for this path.

### 4. Clean orphan run directories conservatively

Add injectable `now` and a fixed orphan grace period. Continue count/age cleanup
for valid records. Treat missing/invalid meta separately: delete only when the
directory timestamp is older than grace, no active claim exists, and it is not
the preserved run. If timestamps cannot be read, keep the directory.

**Verify:** old orphans are removed; recent initialization, claimed runs, and
preserved runs survive; invalid directories do not distort valid maxRuns order.

### 5. Make cancel E2E prove a terminal state

Extract `waitForTerminalRun`; timeout must fail and throw. After cancel, require
`cancelled`, an end time, and disappearance of the claim. Track detached runs in
test teardown; request cancel and wait before deleting the temporary root.

**Verify:** the old non-terminal behavior fails; the new test cannot pass merely
because the deadline elapsed.

### 6. Document the intentional CLI behavior change

Update help and Agent docs: log defaults to tail; full content requires `--full`;
JSON consumers must inspect `truncated`. Preserve existing exit-code meanings.

## Test plan

- Many irrelevant histories plus one target run; corrupt latest directory; safe
  run-ID validation; missing target.
- Small/large/multibyte logs, `--full`, `--bytes`, incompatible flags and errors.
- install destination regular/symlink/directory/special-file cases.
- valid retention count/age plus old/recent/claimed/preserved orphans.
- cancel terminal-state and teardown-on-failure tests.

## Commands and done criteria

- Full Xcode tests, project sync check, and `git diff --check` from Plan 001.
- [ ] CLI default paths never decode all histories for list/status/log.
- [ ] Default log allocation/output is bounded and truncation is machine-visible.
- [ ] Old orphan directories are cleaned without touching active/recent runs.
- [ ] `install-cli --force` never recursively removes a swapped path.
- [ ] Cancel E2E fails on timeout and proves cleanup.

## STOP conditions

- Directed lookup concatenates an unvalidated run ID.
- Latest-run compatibility would be silently removed from existing payloads.
- Default log mode still allocates according to whole file size.
- Retention cannot obtain a reliable timestamp and chooses deletion anyway.
- Fix requires a database/new SSOT or changes public status/exit-code semantics.

## Maintenance notes

Plan 008 must update/generate the CLI result schema for truncation fields. Future
search features should build on bounded query APIs, not restore full scans.
