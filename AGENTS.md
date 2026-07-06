# AGENTS.md

Instructions for AI coding agents working in the **zget** repository.

## Project overview

**zget** is a non-interactive HTTP/HTTPS file downloader written in Zig — similar to `wget` or `curl`. It is a single-binary CLI with progress reporting, speed display, custom headers, and flexible output paths.

| Item | Value |
|------|-------|
| Language | Zig **0.16.0** (see `mise.toml`) |
| CLI parsing | [yazap](https://github.com/prajwalch/yazap) 0.7.0 |
| HTTP | `std.http.Client` via `src/transport.zig` |
| License | MIT |

## Repository layout

```
src/
  main.zig        # CLI entry, download loop, progress UI, unit tests
  transport.zig   # HTTP client wrapper (GET, headers, redirects)
build.zig         # Build, test, run, archive steps
build.zig.zon     # Package manifest and yazap dependency
justfile          # Local build shortcuts (mise + zig)
mise.toml         # Tool versions and CI build task
.github/workflows/  # Cross-platform CI and release
```

There is no `tests/` directory — tests live next to the code they cover (`test` blocks in `.zig` files).

## Build and run

Use **mise** to pin the Zig version, or install Zig 0.16.0 manually.

```bash
# Standard local build
zig build

# Run tests
zig build test

# Run with arguments
zig build run -- -O out.zip https://example.com/file.zip

# Release archive (tar.gz in zig-out/)
zig build archive -Dversion=0.1.3

# Cross-compile example
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
```

Via **just** (wraps mise):

```bash
just build          # ReleaseFast, x86_64-linux-musl, version 0.1.3
just test
```

Via **mise** (used in CI):

```bash
mise run build:zig
```

Binary output: `zig-out/bin/zget` (or custom prefix from `--prefix-exe-dir`).

## Architecture

```
main.zig
  ├── yazap: parse CLI (-H, -O, URI positional)
  ├── resolve output path (file vs directory)
  ├── transport.Transport.get() → sendBodiless() → receiveHead()
  └── stream response body to file with std.Progress + speed stats
```

**`transport.zig`** owns the HTTP client lifecycle. Keep network concerns here; keep `main.zig` focused on CLI orchestration and I/O.

Key behaviors to preserve when changing code:

- `-O` pointing to an existing directory appends the filename from the URL path.
- Non-200 responses return `ZgetError.HttpError` after printing the status.
- Empty target path (no filename in URI and no usable `-O`) returns `ZgetError.ResultFileNotSet`.
- Redirects are enabled via `redirect_behavior` in `transport.zig`.
- `main` uses `init.arena.allocator()` — do not introduce a separate GPA unless there is a clear reason.

## Zig conventions for this repo

- **Minimize scope.** Small, focused diffs. No drive-by refactors.
- **Match existing style.** Follow patterns in `src/main.zig` and `src/transport.zig` for naming, error handling, and allocator use.
- **Use std library first.** HTTP goes through `std.http.Client`; avoid adding dependencies without discussion.
- **Errors.** Project-local errors are grouped (e.g. `ZgetError`). Propagate with `try`; use `catch` only where recovery is intentional (see the read-loop retry logic in `main.zig`).
- **I/O.** This codebase uses Zig 0.16 `std.Io` APIs (`init.io`, `std.Io.File`, `std.Io.Dir`, `std.Io.Clock`). Do not revert to pre-0.16 file APIs.
- **Comments.** Only for non-obvious logic; the code should read clearly on its own.
- **Tests.** Add `test` blocks in the same file as the code under test. Run `zig build test` before finishing.

## Code Style Guidelines
- Follow Zig standard library conventions
- Use snake_case for functions and variables
- Use PascalCase for types and structs
- Use SCREAMING_SNAKE_CASE for constants
- Prefer explicit error handling with `!` return types
- Keep functions small and focused on single responsibility

## Development Rules

### Before Making Changes
1. Read existing code to understand patterns and conventions
2. Check for existing tests related to modified functionality
3. Ensure changes are compatible with existing API

### When Writing Code
1. Write idiomatic Zig code following std lib patterns
2. Handle all errors explicitly - no silent failures
3. Add tests for new functionality
4. Keep backward compatibility when possible

### When Fixing Bugs
1. Understand root cause before fixing
2. Add regression test if missing
3. Check for similar issues in related code
4. Verify fix doesn't break existing tests

## Testing

```bash
zig build test
```

When adding features, prefer table-driven or focused unit tests over integration tests unless HTTP mocking is already in place.

CI runs tests only for `x86_64-linux-gnu/musl` builds (`mise.toml` task). Ensure tests pass on that target.

## CI and releases

- **Branches:** `master`, `develop`; PRs target `master`.
- **CI:** `.github/workflows/ci_build.yml` — matrix build for Linux, Windows, macOS (x86_64 + aarch64).
- **Releases:** Tags `v*` trigger changelog generation (`cliff.toml` / git-cliff) and GitHub release with `.tar.gz` artifacts.
- **Version:** Passed at build time via `-Dversion=...` (`build_options.version` in code). Default: `0.1.0-dev`.

## Commit and PR guidelines

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: redirects support added
fix: speed calculation fixes
chore: readme corrected
ci: migration to mise
build: zig 0.16
refactor: use arena from main init arg
```

- Do **not** commit unless explicitly asked.
- Do **not** push or force-push without explicit request.
- Keep PRs focused; describe what changed and how to verify (`zig build test`, manual download smoke test).

## Security

- Never commit secrets, tokens, or credentials.
- Custom headers (`-H`) may contain sensitive values — do not log or hardcode them in tests.
- Validate user-controlled paths; prefer existing `std.fs.path` helpers over ad-hoc string concatenation.

## What agents should avoid

- Adding large frameworks or unnecessary abstractions for one-off logic.
- Copying entire files into rules or docs — reference paths instead.
- Changing `build.zig.zon` dependency hashes without fetching and verifying the new package.
- Breaking cross-compilation targets listed in CI without updating the workflow.
- Editing `README.md` or this file unless the task requires documentation updates.

## Verification checklist

Before considering a task done:

1. `zig build` succeeds.
2. `zig build test` passes.
3. If CLI behavior changed, smoke-test: `zig build run -- <url>` or with `-O`/`-H` flags.
4. No new compiler warnings in ReleaseFast (CI default).

## Important Notes
- Always verify build passes before completing tasks
- Run full test suite after significant changes
- Follow existing code organization patterns
- Write code comments only in English
- Don't write trivial code comments
- Write tests in AAA pattern - Arange, Act, Assert
- Always apply zig fmt to final result
