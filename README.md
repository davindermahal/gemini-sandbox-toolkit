# gemini-sandbox-toolkit

A shared Gemini CLI Docker sandbox, usable from any project on any of your machines — one image,
one wrapper command, one set of MCP server registrations, instead of copying sandbox files into
every repo.

Full background and the source-cited reasoning behind every decision here:
[davindermahal/gemini-sandbox-toolkit-demo](https://github.com/davindermahal/gemini-sandbox-toolkit-demo)
(a demo project that exists purely to test this toolkit against something real — not a dependency
of the toolkit), particularly `.ai/guides/gemini-docker-sandbox-mcp.md` Section 6.

**New to this toolkit, or explaining it to a teammate?** See [`ARCHITECTURE.md`](ARCHITECTURE.md)
for how the pieces fit together — in particular, why the MCP servers here split into two categories
that update completely differently, and what to check when one isn't loading the version you expect.

## Requirements

Docker (running, and your user in the `docker` group — needed to build the sandbox image; the
sandbox itself does not get access to the host's Docker daemon, see
[Docker access for your project's own containers](#docker-access-for-your-projects-own-containers)),
Node.js, and
`gemini-cli` already installed (`npm install -g @google/gemini-cli`). `install.sh` checks for all
of these up front and exits with a clear message if any are missing, rather than failing partway
through.

## Install

```bash
git clone https://github.com/davindermahal/gemini-sandbox-toolkit ~/.gemini-sandbox
cd ~/.gemini-sandbox
./install.sh
```

What it does:

1. **Checks for a conflicting environment first.** If you've tried setting up a Gemini sandbox by
   hand before (on this machine or another), you may have `GEMINI_SANDBOX_IMAGE`,
   `SANDBOX_FLAGS`, etc. exported somewhere — a stray one of these will collide with this
   toolkit's own, and a stray `GEMINI_SANDBOX_IMAGE` will make plain `gemini` (with
   `GEMINI_SANDBOX` also set from an old rc file) silently use an old image instead of this one.
   The installer reports both the currently-exported environment and matching `export` lines in
   your shell rc files — it doesn't edit them for you, just tells you what to remove.
2. **Builds the image** (`gemini-sandbox:latest`), pinned to *your* installed `gemini-cli`
   version automatically (`gemini --version`) — not hardcoded, so this works correctly across
   machines on different CLI versions, and after you upgrade `gemini-cli` (just re-run
   `install.sh`).
3. **Symlinks `bin/gemini-sandbox` into `~/.local/bin`.**
4. **Registers MCP servers globally** in `~/.gemini/settings.json` — `chrome-devtools-mcp`,
   `ai-intake-mcp`, and `ai-intake-documentation-mcp`, all always on, no configuration needed. This
   **merges** into your existing settings rather than overwriting them, and backs up the original
   once, to `~/.gemini/settings.json.pre-gemini-sandbox-install`, the first time it runs.

Safe to re-run any time — every step is idempotent. `./install.sh` alone is meant to be
sufficient — no `env` file, no variables to set, unless you're doing the local-dev override
described below.

### Updating the baked-in MCP packages

`ai-intake-mcp`, `documentation-mcp`, `confluence-client`, and `chrome-devtools-mcp` are all baked
into the image at pinned versions (`ARG ..._VERSION` near the top of `sandbox.Dockerfile`). To pick
up newer releases:

```bash
make upgrade-mcps         # bump any outdated versions, rebuild + re-register, smoke-test
```

Or step by step: `make check-mcp-versions` (report only) / `make bump-mcp-versions` (write the
`ARG`s) / `./install.sh` (rebuild + re-register) / `./debug.sh` (smoke-test).

Then commit, and see `CLAUDE.md`'s "Releasing" section for cutting a new version/tag.

### Updating `make-runner-mcp`

`make-runner-mcp` is pinned differently from the four packages above — it isn't published to npm
and isn't baked into `sandbox.Dockerfile`; it's a host-side process (see
[Docker access for your project's own containers](#docker-access-for-your-projects-own-containers)
below), version-pinned to a GitHub release tag via the `MAKE_RUNNER_MCP_VERSION=` line in
`bin/gemini-sandbox-mcp-up`. `make upgrade-mcps` bumps this pin too now, but **bumping the pin
alone does not update any project already using it** — `gemini-sandbox-mcp-up` starts a
long-running background process that keeps running whatever version it started with until you
cycle it:

```bash
make check-make-runner-mcp-version   # report only
make bump-make-runner-mcp-version    # write the new tag into bin/gemini-sandbox-mcp-up

# Then, in EVERY project directory with an instance already running:
cd your-project
gemini-sandbox-mcp-down
gemini-sandbox-mcp-up                # relaunches, fetching the newly-pinned tag
```

### Updating the precompiled `better-sqlite3` binary

`better-sqlite3` (an `ai-intake-mcp` dependency) has no prebuilt binary for Node 24 on any
platform yet, so compiling it from source costs ~2 minutes on every image build. To avoid paying
that on every `./install.sh` run, a compiled binary is checked into `prebuilt/better-sqlite3/` and
baked in directly (see `sandbox.Dockerfile`'s comment on the `better-sqlite3-builder` stage). It
only needs regenerating when `better-sqlite3` itself bumps, or the pinned Node major changes:

```bash
make check-better-sqlite3     # is a newer better-sqlite3 available?
make rebuild-better-sqlite3   # recompile prebuilt/ against the current pin (or BETTER_SQLITE3_VERSION=x.y.z)
```

Then bump `ARG BETTER_SQLITE3_VERSION` in `sandbox.Dockerfile` to match, and commit both together.
If the two ever drift apart, `install.sh` doesn't fail — the Dockerfile falls back to compiling
from source and tells you so, both during the build and again at the end of `install.sh`'s output.

### Local-dev override (iterating on either server without publishing)

Copy `env.example` to `env` and set `AI_INTAKE_MCP_DIR` and/or `AI_INTAKE_DOCUMENTATION_MCP_DIR`
to a local clone of that server (built once — `npm install && npm run build`). When set, the
wrapper bind-mounts your clone into the sandbox read-only and registers that in place of the
baked-in image version. From then on, `git pull && npm run build` in the clone before a test run
picks up new commits with no publish and no image rebuild — just re-run `./install.sh` once after
first setting the variable, to switch the registration over.

## Use

From any project directory:

```bash
gemini-sandbox -s -p "run make unit-test"
```

Plain `gemini` (no wrapper) stays unsandboxed — `gemini-sandbox` is the opt-in, not a global
default. Gemini auto-mounts whatever directory you run it from, so this same command works
against any project without any per-project setup.

## Docker access for your project's own containers

The sandbox deliberately has no Docker CLI and no `docker.sock` mount — see "Files" below and
[davindermahal/gemini-sandbox-toolkit-demo](https://github.com/davindermahal/gemini-sandbox-toolkit-demo)'s
`.ai/guides/gemini-docker-sandbox-mcp.md` (Section 0) for the full reasoning: a bind-mounted
`docker.sock` is root-equivalent host access, and because this sandbox is one shared container per
session rather than scoped per-tool, giving it Docker access would hand that same access to
whatever native shell command the model decides to run directly, not just to an MCP server's
vetted targets. That's not a limitation to work around — it's the same reasoning that makes the
sandbox worth using at all.

**Built into this toolkit**, not something you wire up by hand: [`make-runner-mcp`](https://github.com/davindermahal/make-runner-mcp)
runs as its own process *outside* the sandbox — normal host-level Docker access, nothing
special — reached by the sandboxed session only over the network at
`http://host.docker.internal:<port>/mcp`, with a required bearer-token auth (it refuses to start
unauthenticated). `install.sh` puts three commands on your `PATH` for this:

```bash
cd your-project
gemini-sandbox-mcp-up       # start it for THIS project (idempotent — safe to re-run)
gemini-sandbox -s -p "run make unit-test"   # now reachable as an MCP tool inside the sandbox
gemini-sandbox-mcp-down     # stop it
gemini-sandbox-mcp-status   # check whether it's running
```

**Explicit, per-project opt-in — not automatic**, deliberately: a persistent, token-protected,
host-listening server capable of running arbitrary `make` targets is a different risk class than
the transient `stdio` servers this toolkit already auto-registers (those are spawned fresh inside
the sandbox each session, scoped to that one session's lifetime, with no standing host access).
`gemini-sandbox` prints a one-line hint if it sees a `Makefile` in a project that's never run
`gemini-sandbox-mcp-up`, but never starts one on its own.

**Why this isn't just another entry in `merge-settings.js`**: `chrome-devtools-mcp`/`ai-intake-mcp`
are stateless and project-agnostic — spawned fresh, `stdio`, inside the sandbox each session, so
one global registration (done once, at install time) correctly serves every project.
`make-runner-mcp` is a persistent, host-side process scoped to **one project**, so it needs its own
port and token per project — `gemini-sandbox-mcp-up` picks a free port and generates a token the
first time it's run for a given project, stored under `~/.gemini-sandbox-mcp-runner/<key>/`
(`<key>` derived from that project's real path — decoupled from wherever this toolkit itself is
cloned, so it isn't part of this repo's own working tree). `bin/gemini-sandbox` registers the
correct project-specific entry into that project's own `.gemini/settings.json` on every
invocation (touching only that one key — Gemini merges it with the global registrations above
automatically), and removes it again once `gemini-sandbox-mcp-down` stops the process, rather than
leaving a permanently broken entry behind.

Verified end-to-end, including the property that's genuinely new here — two different projects
running simultaneously don't collide (distinct ports and tokens, one project's token rejected
against another's endpoint) — through this toolkit's actual hardened image against real
Docker-driven `make` targets, with the sandboxed session's own native shell tool confirmed to have
zero Docker access throughout.

## Troubleshooting

If `gemini-sandbox` starts but an MCP server shows disconnected (e.g. `MCP error -32000:
Connection closed`), run:

```bash
./debug.sh
```

It launches each registered MCP server directly inside the actual sandbox image and runs a real
MCP handshake with it — the same mechanism `gemini`'s own sandbox uses — with no `gemini`
invocation and no API quota needed. Tells you whether the problem is in the image/mounts (fails
here too) or specific to how `gemini` is spawning things (passes here, fails only through
`gemini`), plus prints the exact registered config and host/container memory info.

**If `debug.sh` passes but it still fails through a real `gemini-sandbox -s` session**, that means
the image and mounts are fine and the problem is specifically in how `gemini` spawns things —
`debug.sh` can't see that, by design. Run:

```bash
./debug-live.sh
```

This drives an actual `gemini -s -d` (debug mode) session and extracts every registered MCP
server's real stderr plus connection lifecycle messages — the diagnostic that actually found a
real bug this way (a symlink-resolution issue in the wrapper itself, not an MCP problem). Makes
one live model call — draws on whatever account/auth `gemini` is already configured with (a
Developer API key, Code Assist via a Google account, Vertex AI), so run `debug.sh` first since it
makes no such call at all.

## Updating on a machine where it's already installed

```bash
cd ~/.gemini-sandbox
git pull
./install.sh
```

## Files

- `sandbox.Dockerfile` — the image: `make` plus a second Node runtime for MCP servers needing a
  newer version than the sandbox's bundled one, Chromium + `chrome-devtools-mcp`, and
  `ai-intake-mcp` + `ai-intake-documentation-mcp` at pinned published versions. No Docker
  CLI/daemon access — nothing inside the sandbox can reach the host's Docker daemon.
- `prebuilt/better-sqlite3/` — checked-in precompiled binary so `install.sh` doesn't recompile
  `better-sqlite3` from source on every run; `Makefile` regenerates it (see "Updating the
  precompiled `better-sqlite3` binary" above).
- `bin/gemini-sandbox` — the wrapper: sets `GEMINI_SANDBOX=docker`, `GEMINI_SANDBOX_IMAGE`, and
  `SANDBOX_MOUNTS` (only ever non-empty for the local-dev override or an admin policy dir, if
  present — deliberately no docker.sock mount); also sets or prunes the current project's
  `makeRunner` MCP registration (see "Docker access for your project's own containers" above)
  before `exec`-ing into `gemini`.
- `env.example` / `env` (gitignored, per-machine) — `AI_INTAKE_MCP_DIR` and
  `AI_INTAKE_DOCUMENTATION_MCP_DIR`, the local-dev override described above. Optional.
- `install.sh` — checks prerequisites and environment, builds the image, and wires everything
  above into place, including the `gemini-sandbox-mcp-*` commands below.
- `merge-settings.js` — the actual `mcpServers` registration logic install.sh runs against the
  **global** `~/.gemini/settings.json`; edit this to add, remove, or change a globally-registered
  server.
- `bin/gemini-sandbox-mcp-up` / `bin/gemini-sandbox-mcp-down` / `bin/gemini-sandbox-mcp-status` —
  manage the persistent, per-project `make-runner-mcp` process described above.
- `bin/mcp-runner-lib.sh` — shared by the three commands above and by `bin/gemini-sandbox` itself:
  project-path→state-directory key derivation, the process-group liveness check, and the
  free-port picker.
- `merge-project-settings.js` — sets or prunes only the `mcpServers.makeRunner` key of a
  **project-local** `.gemini/settings.json`, preserving everything else already there — the
  per-project counterpart to `merge-settings.js`'s global-file role.
- `debug.sh` / `debug-live.sh` — see [Troubleshooting](#troubleshooting) above.
