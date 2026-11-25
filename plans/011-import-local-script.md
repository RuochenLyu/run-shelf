# Plan 011: Import a local script into a new task

## Status

- **Priority:** P2
- **Effort:** S
- **Risk:** LOW
- **Category:** feature, App + Core
- **Planned at:** `main` @ `6f739df`, 2026-11-25
- **Supersedes:** external PR RuochenLyu/run-shelf#3 (rejected design, see "Why not the PR")
- **Credit:** feature proposed and first implemented by @zrtnb6 in RuochenLyu/run-shelf#3

## Why this matters

Reusing an existing script means opening it elsewhere and pasting it into the
blank template. Import should turn a file the user already trusts into a task
that runs the same way it runs in their terminal, with no silent guesses.

## Product contract

1. Import **copies** the file's content into `run.sh`. The task stays
   self-contained and file-native; moving or editing the original later never
   breaks or mutates the task. (Linking to a file in place is already covered by
   the "项目脚本" template's `exec ./run.sh`.)
2. Run Shelf never rewrites the user's script body. The only change allowed is
   normalization (strip UTF-8 BOM, CRLF/CR → LF, trailing newline) and, when the
   file has no shebang, **prepending** one line.
3. The interpreter is chosen only from reliable signals, in this order:
   1. a shebang at byte 0 of line 1 (`#!` exactly, as the kernel requires) —
      kept verbatim;
   2. the file extension;
   3. otherwise `#!/bin/zsh`, Run Shelf's native task language.
   There is **no regex content sniffing**: it misfires on ordinary scripts
   (`awk '{print($1)}'` in `.sh`, `print(` in Perl, `def f(x)` in Ruby, ESM
   `import x from` in `.mjs` all read as Python) and the failure is silent.
   Whenever Run Shelf prepended a shebang the sheet says which one, so a wrong
   default is visible before the task exists and is a one-line edit after.
4. Runs inherit the launching process's environment (`TaskRunner.makeEnvironment`
   copies `ProcessInfo`), and both the LaunchAgent and an App opened from
   Finder/Dock get launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). So
   `#!/usr/bin/env node` works in Terminal and fails in Run Shelf — manual runs
   included. Resolution always uses that hard-coded runtime PATH, never the
   importing process's PATH (which differs under Xcode/Terminal launches):
   - when Run Shelf *chooses* a non-shell interpreter it searches
     `/opt/homebrew/bin`, `/usr/local/bin`, then the runtime PATH, and writes
     the **absolute path** it found. Homebrew first, because `/usr/bin/python3`
     is the CLT shim and `/usr/bin/ruby` is 2.6 — not what the user's terminal
     runs. Not found → `#!/usr/bin/env <name>` plus a notice;
   - when the file's own shebang is `env <name>`, the body is untouched; a
     notice fires if a Homebrew/local copy exists and the runtime PATH would
     resolve to nothing or to a different binary;
   - when the file's own shebang is an absolute path that is not executable
     here (`#!/usr/local/bin/bash` on Apple Silicon), a notice says so, because
     `posix_spawn` would otherwise fail with a bare ENOENT.
   Copying also changes `$0` (now `runs/<id>/run.sh.snapshot`) and the working
   directory (the task directory); child processes still see the runtime PATH.
   README states this in one sentence and points such scripts to "项目脚本".
5. Rejected inputs, each with one short Chinese error: not a regular file after
   resolving symlinks (directories, FIFOs — a FIFO would hang the main thread),
   unreadable, larger than 128 KiB (attribute check first, then a bounded read of
   at most limit + 1 bytes; 128 KiB keeps `DangerousCommandScanner`, which runs
   on every header render, cheap), UTF-16 BOM (specific "convert to UTF-8"
   message), NUL byte, not valid UTF-8 (no lossy or GB18030 guessing — silent mojibake in a
   script is worse than an error), empty after trimming.
6. The created task behaves exactly like any other template-created task:
   same `origin: .app`, same enabled default, schedule taken from the sheet.
   `manifest.description` = `导入自 <~-abbreviated path>`; `notes.md` empty.
   No schema, CLI, lock, or on-disk format change — CLI/App/Scheduler stay
   protocol-compatible and existing tasks are untouched.

### Extension map (only used when there is no shebang)

| Extension | Shebang |
| --- | --- |
| `.zsh`, `.command`, none, `.txt`, anything else | `#!/bin/zsh` |
| `.sh`, `.bash` | `#!/bin/bash` |
| `.py` | resolved `python3` |
| `.js`, `.mjs`, `.cjs` | resolved `node` |
| `.rb` | resolved `ruby` |
| `.pl` | resolved `perl` |
| `.applescript` | `#!/usr/bin/osascript` |

`.sh` maps to bash, not zsh: a shebang-less `.sh` is almost always run as
`bash x.sh` / `sh x.sh`, and zsh's word-splitting and 1-based arrays would
change its behavior.

## UI (must stay quiet)

- The template grid is 4 columns × 7 built-ins, leaving one empty slot. The
  eighth card is **导入文件** (`square.and.arrow.down`). It fills the grid; no
  new section, toolbar, or button row.
- Clicking it opens SwiftUI `.fileImporter` (`[.data]`, single file). The app
  is not sandboxed, but start/stop security-scoped access anyway so the code is
  correct if that changes. Dropping a file anywhere on the sheet imports it too
  (no drop-zone chrome; the card highlights while targeted).
- After import the card shows the file name (middle-truncated) and is selected.
  The existing description line under the grid becomes
  `backup.sh · bash · 42 行`. At most **one** extra caption line, secondary
  color, only when there is something to know:
  - `已补 #!/bin/bash，可在创建后修改`, or
  - `运行时找不到 node，建议改为 #!/opt/homebrew/bin/node`.
  An error replaces that caption in red; the previous import (if any) stays.
- Clicking the selected import card picks another file; clicking it while a
  built-in is selected just re-selects the imported file.
- Name field: no extra state. The imported template's `name` is the file's base
  name, so the existing placeholder and `TaskStore`'s empty-name fallback
  already do the right thing.
- Schedule resets to the default only when switching *to* the import card, like
  any card switch; re-importing while it is selected keeps an edited schedule.
  Cancelling the importer changes nothing.
- Drop target is the sheet's outer container; text fields keep their own text
  drops.
- Creating the task selects it, so the user lands in the editor with the
  imported script and the existing dangerous-command banner.

## Code layout

- `RunShelf/Core/Templates/ScriptImport.swift` (new): `ScriptImport` value
  (script, fileName, sourcePath, interpreter label, lineCount, `notice`) and a
  pure `ScriptImporter` with injectable `isExecutable(path:)` for interpreter
  resolution. `load(from:)` reads; `make(text:fileName:)` is the pure core.
  `TaskTemplate.imported(_:)` builds the in-sheet template
  (id `imported-file`, not in `builtIns`); its `description` is the on-disk
  `导入自 …`, while the sheet's summary line comes from `ScriptImport`.
  `NewTaskSheet.selectedTemplate` must resolve it (today it falls back to
  `.blank`, which would silently create a blank task).
- `RunShelf/App/Views/NewTaskSheet.swift`: card, importer, drop, caption.
  Reuse `TemplateCard` styling instead of a parallel card type.
- `RunShelfTests/ScriptImportTests.swift` (new).
- Files added via `bundle exec ruby scripts/sync_xcodeproj_files.rb`.
- README (zh/en): one bullet + a short subsection. Release notes are written per version in `docs/releases/` at release time (CHANGELOG stopped at 1.4.0).

## Tests

Pure: shebang kept verbatim (incl. `env -S`); leading-space `#!` is not a
shebang; each extension row; no extension / `.txt` → zsh + notice; BOM/CRLF/CR;
trailing newline; empty; line count. Resolution: absolute path picked from
fake directories; Homebrew wins over the runtime PATH; not found → `env` + notice;
own `env node` shebang unresolvable on the runtime PATH → notice, body untouched;
absolute shebang not executable → notice.
File: oversize rejected without reading (sparse file), NUL, invalid UTF-8,
directory, UTF-16. Store: `TaskStore.createTask(from: .imported(...))` in a temp tasks
directory writes `run.sh` byte-identical to the import result, description set,
origin `.app`. All filesystem tests use per-test temp directories; nothing
touches `RUN_SHELF_APP_SUPPORT_DIR` or real data.

## Review

Independent design review (subagent, 2026-11-25) changed: interpreter lookup
order, PATH scope (manual runs too), absolute-shebang check, regular-file and
bounded-read checks, size cap 512 → 128 KiB, UTF-16 message, drop target,
removal of name-field state, separate sheet summary vs. manifest description.
Kept: zsh fallback with a notice for unknown extensions (rejecting would block
valid shebang-less zsh files with odd names).

## Done criteria

- `scripts/check.sh` passes.
- Existing built-in template flow is byte-for-byte unchanged (same task output).
- Manual: import `.sh` without shebang, `.py` without shebang, a file with its
  own shebang, a binary, and drag-drop; sheet never grows more than one line.

## Why not the PR

PR #3 sniffs content before extension (misdetects the cases above), falls back
to GB18030/lossy decoding, reads whole files before the size check, treats an
indented `#!` as a shebang, emits up to three orange warnings, adds a fork
banner to both READMEs, and ignores the launchd PATH problem, so imported
`env node` scripts fail in the background.
