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

1. Make sure `main` is clean and pushed (`git status --porcelain`, `git push origin main` if there
   are unpushed commits) -- the tag should point at a commit already on `origin/main`, not local-only
   work.
2. Decide the next version (semver, judgment call from `git log <last-tag>..HEAD` and `git tag` for
   the last release): patch for a fix, minor for a new capability (e.g. a newly registered MCP
   server, a new install.sh feature), major for a breaking change to how the sandbox or install.sh is
   used.
3. Create an **annotated** tag whose message is the release notes -- this is the only changelog this
   repo has, so write it for that audience. Match the style of `v0.1.0` (`git show v0.1.0`): a
   one-line title, blank line, then a short prose paragraph naming what actually changed -- not a raw
   commit list.
   ```bash
   git tag -a v<version> -m "v<version>

   <1-3 sentence summary of what this release actually contains>"
   ```
4. `git push origin v<version>`. This triggers the release workflow.
5. Watch it: `gh run list --workflow=release.yml` / `gh run watch <run-id>`. Confirm it published:
   `gh release view v<version>`.

If the tag was created without `-a`/`-m` (a lightweight tag), the workflow refuses to publish rather
than creating a release with empty notes -- delete it (`git tag -d v<version>` locally,
`git push origin :refs/tags/v<version>` if already pushed) and redo step 3 properly.
