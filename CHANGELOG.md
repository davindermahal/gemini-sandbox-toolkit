# Changelog

All notable changes to this toolkit are documented here. Versions correspond to tags (`vX.Y.Z`) and
GitHub Releases; each entry's text is also what the release tag itself is annotated with (see
CLAUDE.md's "Releasing" section).

## 0.6.0 — 2026-09-12

### Changed
- `make-runner-mcp` is now pulled via its npm package (`make-runner-mcp@X.Y.Z`) instead of a GitHub
  tag, now that it's published to npm — `bin/gemini-sandbox-mcp-up`'s `MAKE_RUNNER_MCP_VERSION` is a
  bare semver (no `v` prefix) rather than a git tag.
- `check-make-runner-mcp-version`/`bump-make-runner-mcp-version` now use `npm view make-runner-mcp
  version`, the same lookup `check-mcp-versions` already uses for the image-baked packages, instead
  of `git ls-remote --tags`. They still write to `bin/gemini-sandbox-mcp-up`'s own variable rather
  than a `sandbox.Dockerfile` `ARG`, since make-runner-mcp still isn't baked into the image.
- `ARCHITECTURE.md` updated throughout to match (comparison table, lifecycle walkthrough, the
  section on why `make-runner-mcp` keeps its own check/bump targets), plus new sections explaining
  why it runs one instance per project and stays persistent rather than spawned per session.

## 0.5.0 — 2026-09-11

### Added
- `gemini-sandbox-mcp-log`: tails the current project's `make-runner-mcp` log on demand (`-f` to
  follow, `-n N` for more lines) — previously only visible via a startup-failure dump or by finding
  the log file under `~/.gemini-sandbox-mcp-runner/` by hand.
- `gemini-sandbox-mcp-list` / `gemini-sandbox-mcp-down-all`: a cross-project view and a panic
  button, for when you're not sure which project's instance is misbehaving or just want to reset
  everything — list every project this machine has ever started an instance for (running or
  stopped, with pgid/port), or force-stop all of them at once, without `cd`-ing into each project
  first.

## 0.4.0 — 2026-09-11

### Added
- `make check-make-runner-mcp-version` / `bump-make-runner-mcp-version`: `make-runner-mcp` gets its
  own version-check/bump mechanism, folded into `make upgrade-mcps`. It isn't published to npm, so
  it can't use the existing npm-registry-based mechanism — this one resolves the latest `vX.Y.Z`
  git tag directly and writes it into `bin/gemini-sandbox-mcp-up`'s `MAKE_RUNNER_MCP_VERSION=` line.
- `ARCHITECTURE.md`: explains how the toolkit's two categories of MCP server (image-baked/stateless
  vs. `make-runner-mcp`'s host-side/stateful process) differ, and why updating `make-runner-mcp` is
  a two-step process (bump the pin, then separately cycle every project's already-running instance).

### Fixed
- `bin/gemini-sandbox-mcp-up` was still pinned to `make-runner-mcp#v2.0.0`, three releases behind
  current (`v2.0.2`) and with no way to notice short of reading the script — bumped to `v2.0.2`, and
  the README's stale "v2.0.0+" wording removed.

## 0.3.0 — 2026-09-10

### Added
- `make upgrade-mcps`: bumps any outdated baked-in MCP package pins in `sandbox.Dockerfile`,
  rebuilds + re-registers (`./install.sh`), and smoke-tests the MCP handshake (`./debug.sh`) in one
  command. `make check-mcp-versions`/`make bump-mcp-versions` still exist standalone (report-only,
  and bump-without-rebuilding, respectively).
- `CHANGELOG.md` (this file) and a documented "Releasing" process in `CLAUDE.md` covering both the
  routine MCP-upgrade case and cutting a general release.

### Changed
- `chrome-devtools-mcp`'s version is now pinned via `ARG CHROME_DEVTOOLS_MCP_VERSION` in
  `sandbox.Dockerfile`, like the other baked-in packages, so `make bump-mcp-versions` covers it too.

## 0.2.0 — 2026-09-09

### Added
- `.github/workflows/release.yml`: pushing a `v<semver>` tag now creates a GitHub Release
  automatically, using the tag's own annotated message as the release notes.

### Changed
- Bumped the baked-in MCP packages to their latest releases at the time: `ai-intake-mcp` 0.3.2,
  `documentation-mcp` 0.5.1, `confluence-client` 0.1.1, `chrome-devtools-mcp` 1.9.0.

## 0.1.0 — 2026-09-08

### Added
- First tagged release: shared Gemini CLI Docker sandbox, `ai-intake-mcp`/`documentation-mcp` baked
  in at pinned versions with a precompiled `better-sqlite3` binary, `chrome-devtools-mcp`, and
  `make-runner-mcp` lifecycle commands.
