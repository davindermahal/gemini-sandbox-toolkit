# Changelog

All notable changes to this toolkit are documented here. Versions correspond to tags (`vX.Y.Z`) and
GitHub Releases; each entry's text is also what the release tag itself is annotated with (see
CLAUDE.md's "Releasing" section).

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
