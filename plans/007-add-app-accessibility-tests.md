# Plan 007: Add App regression and accessibility coverage

> **Executor instructions:** Preserve the existing visual language. Use native
> controls and stable semantics; do not replace views with snapshot-only tests.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- RunShelf/App/Views RunShelf/Editor scripts/generate_xcodeproj.rb scripts/xcodeproj_sources.rb RunShelf.xcodeproj RunShelfTests`

## Status

- **Priority:** P1
- **Effort:** M
- **Risk:** MED
- **Depends on:** Plans 001 and 006
- **Category:** tests, accessibility
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

Core tests can stay green while editor bindings, log lifecycle, permission UI,
keyboard navigation, and VoiceOver semantics are broken. Native controls also
provide more reliable automation surfaces than gesture-driven cards and unlabeled
icon buttons.

## Current state

- Source routing places only `RunShelf/Core/` and `RunShelfTests/` in the unit
  test target at `scripts/xcodeproj_sources.rb:27`.
- `NewTaskSheet` template cards use ordinary views with `onTapGesture` around
  lines 34-50 and do not expose selected state.
- `ContentView.windowActionBar` has icon-only new/run/save/delete buttons at
  lines 80-119; `.help` is not a stable accessibility identity.
- `TaskHeaderView` contains icon-only stop/more actions.
- The project generator currently creates one unit-test target only.

## Scope

**In scope:** template selection controls, icon action labels/identifiers, exact
test-source routing, optional minimal `RunShelfUITests` target, test launch
environment, and focused App tests.

**Out of scope:** visual redesign, localization expansion, changing command
shortcuts, Core business logic, permission policy (Plan 006), and full TaskStore
refactor.

## Steps

### 1. Choose the smallest reliable App test layer

Keep pure Editor/Service tests in `RunShelfTests` through exact source whitelist.
If SwiftUI accessibility trees cannot be verified there, create a minimal
`RunShelfUITests` target in `generate_xcodeproj.rb` and the shared source-routing
model. Do not manually maintain target membership only in pbxproj.

**Verify:** generator/sync are idempotent and test targets build without importing
unrelated App lifecycle services.

### 2. Use native template-selection controls

Make each template card a Button while preserving layout/style. Support Tab,
Space, and Return. Expose template name and selected state via standard selected
trait/value. Avoid stacking an invisible button over a gesture recognizer.

**Verify:** keyboard-only selection changes the chosen template exactly once and
VoiceOver reports the selected card.

### 3. Label every audited icon action

Use `Label(title, systemImage:)` with `.labelStyle(.iconOnly)` where possible;
otherwise add explicit accessibility labels and stable identifiers. Cover new,
run, save, delete, stop, and more actions. Labels must be unique within the
visible screen and match the existing Chinese terminology.

**Verify:** App/UI tests locate each action by semantic identifier/label, not view
coordinates or SF Symbol names.

### 4. Add focused App regressions

Cover editor A→B binding from Plan 001, unauthorized manual mode from Plan 006,
template keyboard selection, action availability/labels, and one live-log refresh
smoke path from Plan 004 if already landed. Use a temporary
`RUN_SHELF_APP_SUPPORT_DIR`; never read/write real user tasks.

**Verify:** repeated test runs are order-independent and leave no process/helper
or temporary task state behind.

## Commands and done criteria

- `bundle exec ruby scripts/sync_xcodeproj_files.rb && bundle exec ruby scripts/sync_xcodeproj_files.rb --check`
- Full Xcode test command from Plan 001, including any new UI target in the scheme.
- Run the App/UI test subset three times; all pass without real-time 15-second waits.
- `git diff --check` has no output.
- [ ] Native keyboard and VoiceOver semantics exist for template choice/actions.
- [ ] Tests use temporary App Support and stable semantic selectors.
- [ ] Project generation remains idempotent.

## STOP conditions

- Tests need to mutate real Login Items, notification permissions, or user tasks.
- Adding exact Editor sources drags the entire App lifecycle into unit tests.
- UI tests can pass only through coordinates, sleeps, or screenshots.
- Visual behavior must be substantially redesigned to obtain semantics.

## Maintenance notes

New icon-only actions must ship with semantic labels and tests. Keep the UI test
suite small; business logic belongs in Core unit tests.
