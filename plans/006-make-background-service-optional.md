# Plan 006: Make background scheduling optional in practice

> **Executor instructions:** Follow the documented product decision: editing and
> manual runs work without Helper authorization. Do not auto-register services or
> mutate task enabled flags behind the user's back.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- README.md RunShelf/RunShelfApp.swift RunShelf/App/Views/PermissionGateView.swift RunShelf/App/Services/SchedulerServiceController.swift RunShelf/App/Views/SettingsView.swift RunShelfTests docs`

## Status

- **Priority:** P1
- **Effort:** M
- **Risk:** MED
- **Depends on:** Plan 001
- **Category:** bug, product contract
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

README says the background service is optional and manual/editing functions remain
available, but startup replaces the entire App with a hard gate and closing that
gate terminates the process. This plan makes authorization a capability state,
not an application-access state.

## Current state

- `README.md:28-34` defines optional background scheduling.
- `RunShelfApp` snapshots authorization into `isGateActive` and conditionally
  replaces `ContentView` at lines 14-30; save/run commands are disabled by it.
- `PermissionGateView` offers registration/settings/quit, and its window delegate
  calls `NSApp.terminate` on close at lines 204-210.
- MenuBarExtra already exposes an unauthorized badge at
  `RunShelfApp.swift:103-116`.

## Scope

**In scope:** App authorization policy, gate/prompt UI, settings/status copy,
menu/command enablement, policy tests, minimal README/development updates.

**Out of scope:** SMAppService protocol changes, signing/notarization, scheduler
logic, automatic registration, task-enabled mutation, and general visual redesign.

## Steps

### 1. Extract a pure capability policy

Represent authorized, disabled, requires-system-approval, and embedded-helper-
missing states. The policy controls prompt text and scheduled capability only;
it never decides whether `ContentView` exists. Inject state in tests so no test
changes the user's Login Items.

**Verify:** unit tests cover every controller status without touching SMAppService.

### 2. Always expose the main task console

Remove authorization as a condition for `ContentView`, Cmd+S, Cmd+R, Cmd+W, and
the manual-run menu. Start with the task console even when authorization is absent.
Keep a non-blocking badge/banner/settings affordance explaining that closed-App
scheduling needs authorization.

**Verify:** unauthorized launch can edit, save, and manually run a fixture task.

### 3. Convert the gate into a dismissible prompt

Retain register/open-settings actions and add “later”. Closing the prompt must not
terminate the App. If the embedded helper is missing, report that background
scheduling is unavailable while leaving manual use accessible. Remove the custom
terminate-on-close delegate if no longer necessary.

**Verify:** close/dismiss keeps the process and task window alive; requiresApproval
can open settings and return without blocking the console.

### 4. Make scheduled limitations explicit without changing data

When a task is enabled but the helper is disabled, show “background scheduling
inactive” in settings/inspector. Do not set `manifest.enabled = false`; users may
later authorize without losing intent. Manual run remains enabled.

### 5. Add App smoke coverage and update docs

Test unauthorized console access, prompt dismissal, helper-missing behavior,
manual run, menu commands, and post-authorization diagnostic refresh. Retire
`RUN_SHELF_BYPASS_GATE` only if no test path still needs it. Keep README and UI
wording consistent.

## Commands and done criteria

- Run project sync, full Xcode tests, and `git diff --check` from Plan 001.
- `rg -n 'isGateActive|windowShouldClose|NSApp\.terminate' RunShelf/RunShelfApp.swift RunShelf/App/Views/PermissionGateView.swift`
  must find no unauthorized-path hard block/termination; explicit user Quit may remain.
- [ ] Unauthorized users can edit/save/manual-run.
- [ ] Only scheduled-after-close capability is unavailable.
- [ ] No test mutates real Login Items.

## STOP conditions

- Product documentation is deliberately changed to make Helper mandatory before execution.
- Manual execution in fact depends on the helper; report the dependency first.
- Tests require real service registration/system settings mutation.
- Fix expands into signing, packaging, or launch-service protocol changes.

## Maintenance notes

Future onboarding should consume the same capability policy. Do not reintroduce a
separate Boolean gate that diverges from scheduler diagnostics.
