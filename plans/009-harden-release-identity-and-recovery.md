# Plan 009: Harden version identity and release recovery

> **Executor instructions:** Tests must use temporary repositories and stubbed
> tools. Never push, tag a real remote, sign, notarize, or read real credentials
> while implementing this plan.
>
> **Drift check:** `git diff --stat a463de3..HEAD -- scripts/package_release.sh scripts/release.sh scripts/generate_xcodeproj.rb RunShelf.xcodeproj docs/release.md .release.env.example scripts/check.sh`

## Status

- **Priority:** P1
- **Effort:** L
- **Risk:** MED
- **Depends on:** Plan 008
- **Category:** release, dx
- **Planned at:** commit `a463de3`, 2026-07-12, plus existing dirty workspace

## Why this matters

Release filenames contain a version, but the App bundle does not. The release
script can also tag an unintended commit, pushes `main`, then creates the GitHub
Release; a failure leaves a partial state that every rerun rejects. Release must
verify identity before publication and resume only when existing state matches.

## Current state

- `generate_xcodeproj.rb:94-107` sets App identity but no
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`.
- `package_release.sh:4,20-23` uses version only in artifact paths and its build
  invocation does not inject bundle versions.
- `release.sh:79-98` rejects every existing local tag, remote tag, or Release.
- `release.sh:118-128` creates a tag, pushes `main` and tag, then creates Release.
- Release documentation includes credential configuration; plans/checks must name
  only credential types and paths, never values.

## Scope

**In scope:** generated Xcode version defaults, packaging version injection and
verification, release preflight/state machine, offline shell tests, placeholders,
and release docs.

**Out of scope:** rotating or changing real credentials, changing signing/notary
provider, performing a release, changing supported macOS, and automatic asset
overwrite when identity is uncertain.

## Steps

### 1. Give every build an explicit bundle identity

Set generated App defaults (`MARKETING_VERSION=0.0.0`,
`CURRENT_PROJECT_VERSION=0`) in `generate_xcodeproj.rb` and sync pbxproj. Define
and document how semantic release versions map to numeric bundle build versions;
if the team requires a distinct monotonically increasing build number, stop for
that decision rather than inventing one.

**Verify:** a normal Debug build contains both Info.plist keys.

### 2. Inject and verify package version before signing

Validate the version argument, pass version settings to xcodebuild, then use
`plutil` to compare both built keys with the requested mapping before codesign or
notary steps. Artifact filenames, bundle value, tag, and release title must derive
from the same normalized version variable.

**Verify:** an unsigned fixture build for `9.8.7` reports the expected values;
mismatch fails before any signing command.

### 3. Preflight the exact release commit

Before packaging, require clean tree, configured release branch, fetched remote,
and `HEAD == origin/<release-branch>`. Require release notes to exist and be
tracked in HEAD. Run `scripts/check.sh`, package, and validate all artifacts before
creating any tag. Remove unconditional `git push origin main`; only a confirmed
tag needs publication.

**Verify:** ahead, behind, wrong branch, dirty tree, and untracked notes all fail
without tag/push/gh mutation.

### 4. Make publication resumable only on proven identity

- Create local annotated tag only if absent; if present, require same commit.
- For remote tag, compare peeled commit; same commit continues, mismatch stops.
- If Release absent, create with four expected assets.
- If Release and all assets exist with proven checksums, return success.
- If assets are missing, upload only missing files.
- If a same-name asset cannot be proven identical, fail; never use blind clobber.

Extract decision logic into testable shell functions or a library sourced by the
entrypoint.

### 5. Add offline release workflow tests

Use temporary bare/local Git repos and stub `gh`, `git push`, signing, and notary
commands. Test first release, wrong HEAD, matching/mismatched local and remote
tags, complete rerun no-op, missing asset recovery, and uncertain asset refusal.
No test may access network, keychain, or the real origin.

### 6. Update release documentation safely

Document branch/HEAD requirements, version mapping, resumable states, and failure
recovery. Use placeholders for signing identity/profile and reference ignored
local config by path only. Replace any self-matching credential scan with the
tracked-file path-only check from Plan 008.

## Commands and done criteria

- `scripts/tests/release_workflow_test.sh` → exit 0 without network or mutations.
- `scripts/check.sh` → exit 0.
- Unsigned build + `plutil` fixture verifies requested bundle version.
- [ ] No publish action occurs before all local checks/artifacts succeed.
- [ ] Release rerun is safe for matching state and refuses ambiguous state.
- [ ] No unconditional push of the release branch remains.
- [ ] No credential value appears in tests, plans, logs, or docs.

## STOP conditions

- Bundle build-number mapping is undecided.
- Default/release branch cannot be determined from repository policy.
- Any existing tag points to another commit.
- Existing remote asset identity cannot be proven.
- Implementation/testing requires real credentials, network publication, or push.

## Maintenance notes

The release script should orchestrate `scripts/check.sh`; it must not copy the
gate list. Reviewers should test reruns after each simulated partial failure.
