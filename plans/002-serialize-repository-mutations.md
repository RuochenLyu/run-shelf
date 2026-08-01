# Plan 002: Serialize cross-process repository mutations

> **Executor instructions:** This changes the lock protocol shared by App,
> Scheduler, and CLI. Implement it as one compatible unit. Never ship a partial
> state where different binaries use different lock locations.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- RunShelf/Core/Storage/TaskRepository.swift RunShelf/Core/Runner/TaskRunClaim.swift RunShelfTests`
> The live workspace includes uncommitted changes; mismatch with the current-state
> facts below is a STOP condition.

## Status

- **Priority:** P0
- **Effort:** L
- **Risk:** HIGH
- **Depends on:** `plans/001-prevent-definition-data-loss.md`
- **Category:** bug, concurrency
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

The current per-task lock lives inside the directory that deletion moves away.
A waiting process can therefore acquire an old lock inode and recreate the
deleted task via `.run-claim`. Slug uniqueness is also a check-then-write outside
a repository transaction, so two processes can create the same slug. Both break
the shared-filesystem contract.

## Current state

- `TaskDefinitionFileLock.withLock(at:)` opens
  `<task>/.definition-lock` at `TaskRepository.swift:17-33`.
- `writeTask` checks directory existence before locking, then creates `runs/`
  inside the lock at `TaskRepository.swift:301-326` without revalidation.
- `deleteTask` holds that movable lock while trashing/moving the entire directory
  at `TaskRepository.swift:351-373`.
- `TaskRunClaimManager.acquire` takes a shared definition lock, then calls
  `createDirectory(...withIntermediateDirectories: true)` at
  `TaskRunClaim.swift:105-107`.
- `createTask` and `updateTask` call `ensureUniqueSlug` before their per-task write
  at `TaskRepository.swift:225-250` and `265-296`.

## Scope

**In scope:** `TaskRepository.swift`, `TaskRunClaim.swift`, `RunShelfPaths.swift`,
focused concurrency tests, source-sync files if a new test file is added, and
minimal development documentation for the lock protocol.

**Out of scope:** database/index introduction, run-history query optimization,
TaskSpec schema changes, UI changes, and compatibility with arbitrarily old
separately installed CLI binaries without an explicit version gate.

## Git workflow and commands

- Branch: `codex/002-serialize-repository-mutations`
- Commit example: `fix(storage): serialize repository mutations`
- Verify with the full Xcode test command from Plan 001, project sync check,
  `git diff --check`, and at least 100 repetitions of the focused race tests.

## Steps

### 1. Write deterministic concurrency regressions

Cover two repositories racing to create the same slug, two updates racing to the
same slug, delete vs claim, delete vs write, and active-claim delete refusal.
Each outcome must be binary: exactly one slug winner; or a complete task versus
fully missing task. No test may accept a partial directory.

**Verify:** old implementation reproduces at least the lock-location invariant
failure; fixtures do not touch the user's real App Support directory.

### 2. Introduce stable lock paths and one lock order

Store locks under `tasks/.locks/`: one repository lock and one task lock per ID.
Change the lock API to take the stable tasks root and validated task ID. Document
and enforce this order:

1. repository lock when namespace/slug/directory membership changes;
2. task lock for definition/claim coordination;
3. never acquire repository after task lock.

Create `.locks` with owner-only permissions and exclude it from task enumeration.

**Verify:** shared task locks coexist; exclusive locks serialize; no reverse
acquisition exists under `rg 'TaskDefinitionFileLock|Repository.*Lock' RunShelf`.

### 3. Revalidate under the stable task lock

After acquiring the task lock, re-check directory existence, basename, and
manifest identity before any write or claim creation. Claim acquisition must
create only `.run-claim` below an already verified task root; it must not create
missing parent directories. Delete must reload/revalidate under its locks before
checking active claims and moving the directory.

**Verify:** a waiter after delete returns task-missing and the original directory
never reappears.

### 4. Make slug uniqueness transactional

Run ID existence check, slug check, directory creation, and initial write inside
one repository critical section. Updates and direct full-task writes that change
or preserve a slug must validate uniqueness in the same section. Rename the
helper to make its “repository lock already held” precondition explicit.

**Verify:** concurrent create/update tests produce exactly one success and final
repository scan reports unique slugs.

### 5. Define upgrade behavior

Update development/release notes: App, embedded helper, and CLI in one bundle
must move together. Remove stale in-task lock files only as best-effort cleanup;
they are not authoritative. If separately installed old binaries can remain
active, add a minimum-version refusal or explicit migration handshake rather
than assuming dual locking solves waiters already blocked on old inodes.

## Test plan

- Model filesystem fixtures on existing temporary-directory helpers.
- Add repeated two-instance races for create/update.
- Add a controlled lock waiter test for delete/claim and delete/write.
- Assert no `.run-claim`, `runs`, or definition fragments remain after deletion.
- Assert active `allow` and `skip` claim behavior is unchanged.

## Done criteria

- [ ] All namespace changes use repository → task lock order.
- [ ] No authoritative lock is inside a movable task directory.
- [ ] Delete cannot be followed by task-root resurrection.
- [ ] Concurrent writers cannot create duplicate slugs.
- [ ] Full tests and 100 focused race repetitions pass.

## STOP conditions

- Lock-protocol version compatibility across shipped binaries cannot be assured.
- Any code path acquires task lock before repository lock.
- A race produces deadlock, duplicate slug, resurrected root, or partial task.
- Fix requires silently changing concurrency=`skip`/`allow` semantics.

## Maintenance notes

Every future mutation of task directory membership or slug namespace must use
the repository lock. Every future writer/claim operation must revalidate after
acquiring the stable task lock.
