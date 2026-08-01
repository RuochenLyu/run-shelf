# Plan 008: Establish generated schemas and one CI gate

> **Executor instructions:** Local and CI verification must call the same script.
> CI must never sign, notarize, publish, or access release credentials.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- schemas RunShelf/CLI scripts RunShelf.xcodeproj Gemfile Gemfile.lock CONTRIBUTING.md docs .github AGENTS.md CHANGELOG.md RunShelfTests`

## Status

- **Priority:** P1
- **Effort:** L
- **Risk:** MED
- **Depends on:** Plans 003, 005, and 007
- **Category:** dx, tests, docs
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

The repository has passing tests but no one-command full gate or CI. Schemas are
manually duplicated in Swift, so declared Agent contracts can drift from CLI
output and runtime. Source membership, dual-architecture build, scripts, plist,
and docs currently depend on maintainers remembering separate checks.

## Current state

- `RunShelfCLI.swift:909-963` embeds hand-copied task/result schemas.
- `schemas/*.json` are also checked in as public contracts.
- `scripts/sync_xcodeproj_files.rb --check` already provides an idempotent source
  membership gate.
- CONTRIBUTING documents Xcode tests but there is no `scripts/check.sh` and no
  `.github/workflows/`.
- No root `AGENTS.md` describes source-development constraints.
- Requirements/roadmap/changelog contain status drift relative to implemented
  menu bar, dangerous-command warnings, and the 1.1.x release notes.

## Scope

**In scope:** generated schema source/checker, CLI schema E2E tests, unified check
script, macOS CI, root agent guide, source-sync integration, and narrow factual
documentation reconciliation.

**Out of scope:** changing TaskSpec semantics beyond Plan 003, release publishing,
signing/notarization, dependency upgrades, broad requirements rewrite, and exposing
credential values or match content in checks.

## Steps

### 1. Generate embedded Swift schemas from JSON SSOT

Add `scripts/generate_cli_schemas.rb` that parses/canonicalizes `schemas/*.json`
and writes `RunShelf/CLI/GeneratedSchemas.swift` with a generated warning. Support
`--check` that exits nonzero without writing when output differs. Reject raw-string
delimiter collisions instead of guessing. Remove manual constants from
`RunShelfCLI.swift` and consume the generated symbols.

**Verify:** generator is idempotent; CLI schema commands parse as JSON and compare
semantically equal to checked-in files in E2E tests.

### 2. Add one local check script

Create `scripts/check.sh` with fail-fast, readable phases:

1. `bundle check`;
2. parse schema JSON;
3. generated schema `--check`;
4. Xcode source sync `--check`;
5. Ruby and Shell syntax checks;
6. plist lint;
7. full Xcode tests;
8. Debug build with `ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO`;
9. `git diff --check`.

Use `.build/` for derived artifacts. Do not format or mutate tracked source.

**Verify:** one `scripts/check.sh` invocation exits 0 on the known baseline.

### 3. Add macOS CI as a thin wrapper

Create `.github/workflows/check.yml` triggered for pull requests and default-branch
pushes. Install the Bundler version implied by `Gemfile.lock`, cache only safe build
dependencies, and invoke `scripts/check.sh` as the sole business gate. Select an
Xcode image that supports guarded macOS 26 APIs and deployment target 15; never
lower targets to accommodate the runner.

**Verify:** workflow YAML parses and a real PR run passes on arm64+x86_64 build.

### 4. Add a root source-development guide

Create `AGENTS.md` covering App/Core/CLI/Scheduler boundaries, file SSOT, temporary
`RUN_SHELF_APP_SUPPORT_DIR`, incremental project sync, generated schemas,
`scripts/check.sh`, Conventional Commits, and no tag/push/release without explicit
authorization. Keep `docs/agent-usage.md` focused on operating the product.

### 5. Reconcile factual documentation drift

Make CONTRIBUTING/development point to `scripts/check.sh` while retaining focused
commands. Mark original requirements versus delivered state without rewriting
history. Align roadmap audit date and CHANGELOG only with verified release notes.
Tracked-secret checks, if added, must print file paths/credential types only,
exclude ignored local config, and use placeholders in examples.

## Test plan

- Generated output equality and drift failure.
- CLI schema command semantic equality for both schemas.
- `check.sh` fail-fast tests where practical for a deliberately drifted generated
  file in a temporary copy.
- CI validation on PR; source-sync remains idempotent after new test/source files.

## Done criteria

- [ ] `schemas/*.json` are the only hand-maintained schema source.
- [ ] `scripts/check.sh` is the documented local and CI gate and exits 0.
- [ ] CI performs tests + universal Debug build without credentials.
- [ ] Root `AGENTS.md` protects real user data and repo workflows.
- [ ] Docs reflect verified current capability and release history.

## STOP conditions

- Strict TaskSpec/timezone behavior from Plan 003 is not settled.
- CI image lacks the required SDK; do not delete guarded APIs or lower support.
- Generated CLI needs runtime access to repository paths.
- A check would print credential contents or require local release configuration.
- Documentation changes would alter product policy rather than correct factual drift.

## Maintenance notes

Every schema edit must regenerate and pass `--check`. Future gates belong in
`scripts/check.sh`; do not duplicate them directly in workflow YAML or release.sh.
