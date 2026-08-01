# Run Shelf development contract

- `RunShelf/Core` owns the file-native task, run, claim, scheduler, and repository contracts.
- App views consume `TaskStore`; they must not coordinate filesystem locks or process claims.
- CLI, App, and Scheduler use the same task directory and must ship together when lock or schema protocols change.
- Tests and tools must set `RUN_SHELF_APP_SUPPORT_DIR` to a temporary directory. Never mutate the user's real Run Shelf data.
- `schemas/*.json` are the hand-maintained schema SSOT. Regenerate `RunShelf/CLI/GeneratedSchemas.swift` with `scripts/generate_cli_schemas.rb`.
- Add or move Swift files with `bundle exec ruby scripts/sync_xcodeproj_files.rb`; do not hand-edit target membership.
- Run `scripts/check.sh` before handoff. Commits follow Conventional Commits 1.0.0.
- Never tag, push, notarize, publish, or read release credentials without explicit operator authorization.
