# Plan 003: Enforce one executable TaskSpec contract

> **Executor instructions:** Treat the checked-in schema as a public Agent
> contract. Reject unsupported input; do not add timezone behavior in this plan.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- schemas RunShelf/Core/TaskModel/TaskModels.swift RunShelf/Core/Storage/TaskRepository.swift RunShelf/CLI/RunShelfCLI.swift RunShelfTests`

## Status

- **Priority:** P0
- **Effort:** M
- **Risk:** MED
- **Depends on:** Plans 001 and 002
- **Category:** bug, API contract
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

The schema promises `additionalProperties: false`, but Swift `JSONDecoder`
silently ignores unknown fields. The runtime also accepts arbitrary timezone
strings while the scheduler always uses local time. Agent typos can therefore
return success while doing something different from the request.

## Current state

- `schemas/task-spec.schema.json:6` rejects unknown top-level fields and line 27
  rejects unknown schedule fields.
- Its timezone is only `{ "type": "string" }` at lines 35-37.
- `TaskSchedule.validationError` checks type and cron expression, not timezone,
  at `TaskModels.swift:51-60`.
- `RunShelfCLI.readTaskSpec` directly calls `decoder.decode(TaskSpec.self, ...)`
  at `RunShelfCLI.swift:518-530`.
- The same schemas are manually copied into `RunShelfCLI.swift:909-963`.

## Scope

**In scope:** task model/decoder, repository validation, both schema JSON files,
CLI schema command/constants, CLI/Core tests, and Agent usage documentation.

**Out of scope:** UTC/IANA timezone execution, database migrations, changing
existing field names, changing exit-code numbers, and general CLI redesign.

## Steps

### 1. Add contract regressions

Test file and stdin inputs for unknown top-level field `enable`, unknown nested
schedule field, wrong types, non-local timezone, minimal create, partial update,
and valid `timezone: local`. Assert JSON errors remain structured with exit code
4 and identify the offending field path.

**Verify:** unknown fields and non-local timezone tests fail on old behavior;
existing valid TaskSpec E2E tests remain green.

### 2. Add a single strict decoder

Create one Core-level TaskSpec decoding boundary used by dry-run and real apply.
It must enumerate allowed keys at the root and schedule object before delegating
type decoding. A custom Decodable implementation must preserve existing
memberwise/test initializers explicitly. Never maintain a second CLI-only list.

**Verify:** every TaskSpec entry point rejects the same unknown fields and emits
the existing `validation` envelope.

### 3. Make local timezone an explicit invariant

Change the schema timezone to `const: "local"` and update
`TaskSchedule.validationError`/repository validation to reject every other value.
App, CLI dry-run, CLI apply, and scheduler must share the same conclusion.

**Verify:** `UTC`, IANA names, empty value, and mixed-case variants fail; `local`
passes without changing next-run calculation.

### 4. Remove hand-maintained schema drift

As an interim gate, make CLI schema E2E output semantically equal to each file in
`schemas/`. Prefer completing the generated-constant mechanism specified in Plan
008; if Plan 003 lands first, update both copies and add the equality test now so
future drift fails loudly.

### 5. Update contract documentation

Document that unknown fields are hard errors and timezone currently supports
only `local`. Preserve the existing dry-run, expected-revision, dangerous-command,
and exit-code workflow.

## Commands

- Project sync and full test command from Plan 001.
- Focused CLI E2E tests: use the existing `RunShelfCLIE2ETests` scheme coverage.
- `ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' schemas/task-spec.schema.json`
  must exit 0.
- `git diff --check` must produce no output.

## Done criteria

- [ ] Unknown root and nested fields are rejected before mutation.
- [ ] Only `timezone: local` is accepted everywhere.
- [ ] CLI schema output and checked-in schema are semantically equal.
- [ ] Valid old specs within the documented schema still work.
- [ ] Error envelopes and exit codes remain compatible.

## STOP conditions

- A documented valid historical TaskSpec shape would be rejected unexpectedly.
- Any entry point bypasses the strict decoder or shared schedule validation.
- Implementing rejection appears to require adding non-local scheduling support.
- Schema output and runtime accepted-field sets still differ after the change.

## Maintenance notes

Plan 008 will make schema generation the permanent SSOT. Future timezone support
must be a separate design with DST and calendar tests before widening the schema.
