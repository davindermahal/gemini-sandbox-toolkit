# Project context

`gemini-sandbox-toolkit`: shared Gemini CLI Docker sandbox + MCP server registration, installed via
`./install.sh`. Not an npm package -- nothing in this repo is published to npm, and there is no
`package.json`/`VERSION` file tracking a version number. A version here is just a git tag.

## Releasing

Publishing happens **only** via a pushed `v<semver>` tag -- `.github/workflows/release.yml` picks it
up and creates the GitHub Release automatically, using the tag's own annotated message as the release
notes. Pushing the tag *initiates* the release; there's no local `gh release create` step and no npm
publish of any kind for this repo -- don't run either by hand, that just races or duplicates what the
workflow already does.

### Routine MCP package updates (the common case)

If this release is just picking up newer versions of the baked-in MCP packages (`ai-intake-mcp`,
`documentation-mcp`, `confluence-client`, `chrome-devtools-mcp`) and nothing else:

1. `make upgrade-mcps` -- bumps any outdated `ARG`s in `sandbox.Dockerfile`, rebuilds the image and
   re-registers the MCP servers (`./install.sh`), then smoke-tests that the baked-in servers still
   pass their MCP handshake (`./debug.sh`, see its "responded correctly" lines). Idempotent -- a
   no-op rebuild if nothing was outdated (`make check-mcp-versions` alone just reports, without
   changing or rebuilding anything, if you want to look before bumping).
2. Continue at step 2 of the general process below (decide the version bump, write the changelog
   entry, etc.) -- the version-bump lines `make upgrade-mcps` printed already tell you exactly which
   package went from what to what, which is most of what the changelog entry needs to say.

### General process

1. Make sure `main` is clean and pushed (`git status --porcelain`, `git push origin main` if there
   are unpushed commits) -- the tag should point at a commit already on `origin/main`, not local-only
   work.
2. Decide the next version (semver, judgment call from `git log <last-tag>..HEAD` and `git tag` for
   the last release): patch for a fix, minor for a new capability (e.g. a newly registered MCP
   server, a new install.sh feature, an MCP package version bump), major for a breaking change to how
   the sandbox or install.sh is used.
3. Add a dated entry to `CHANGELOG.md` (`## <version> — YYYY-MM-DD` with `### Added`/`### Changed`/
   `### Fixed` subsections, matching existing entries) describing what actually changed -- not a raw
   commit list.
4. Commit the changelog (and any other release-related changes, e.g. `sandbox.Dockerfile` from the
   MCP bump above).
5. Create an **annotated** tag whose message is the *same text* as the CHANGELOG.md entry's body
   (single draft, used for both -- see `v0.1.0`/`v0.2.0` via `git show <tag>` for the style already
   in use: a one-line title, blank line, then a short prose paragraph).
   ```bash
   git tag -a v<version> -m "v<version>

   <same 1-3 sentence summary just written into CHANGELOG.md>"
   ```
6. `git push origin main` (if step 4's commit hasn't been pushed yet), then
   `git push origin v<version>`. Pushing the tag triggers the release workflow.
7. Watch it: `gh run list --workflow=release.yml` / `gh run watch <run-id>`. Confirm it published:
   `gh release view v<version>`.

If the tag was created without `-a`/`-m` (a lightweight tag), the workflow refuses to publish rather
than creating a release with empty notes -- delete it (`git tag -d v<version>` locally,
`git push origin :refs/tags/v<version>` if already pushed) and redo step 5 properly.
