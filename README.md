# gemini-sandbox-toolkit

A shared Gemini CLI Docker sandbox, usable from any project on any of your machines — one image,
one wrapper command, one set of MCP server registrations, instead of copying sandbox files into
every repo.

Full background and the source-cited reasoning behind every decision here:
[davindermahal/gemini-sandbox](https://github.com/davindermahal/gemini-sandbox), particularly
`.ai/guides/gemini-docker-sandbox-mcp.md` Section 6.

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

### Updating `ai-intake-mcp` / `ai-intake-documentation-mcp`

Both are baked into the image at pinned versions (`sandbox.Dockerfile`), the same way
`chrome-devtools-mcp` is. To pick up a new release: publish it from that server's own repo, bump
the matching `ARG ..._VERSION` near the top of `sandbox.Dockerfile`, then `./install.sh`.

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
[davindermahal/gemini-sandbox](https://github.com/davindermahal/gemini-sandbox)'s
`.ai/guides/gemini-docker-sandbox-mcp.md` (Section 0) for the full reasoning: a bind-mounted
`docker.sock` is root-equivalent host access, and because this sandbox is one shared container per
session rather than scoped per-tool, giving it Docker access would hand that same access to
whatever native shell command the model decides to run directly, not just to an MCP server's
vetted targets. That's not a limitation to work around — it's the same reasoning that makes the
sandbox worth using at all.

**If your project's own `make` targets need to drive Docker** (`make up`, `make test`, `make
composer {ARGS}`, etc.), the correct pattern is: run an MCP server that talks to Docker as its own
process *outside* this sandbox — normal host-level access, nothing special — and register it with
the sandboxed `gemini` session as an **HTTP**-type MCP server (not the `stdio` `command`/`args`
shape every server in this toolkit currently uses), pointed at
`http://host.docker.internal:<port>/mcp` — reachable automatically, no extra `SANDBOX_MOUNTS` or
network config needed (Gemini's sandbox auto-maps that hostname to the host).

[`make-runner-mcp`](https://github.com/davindermahal/make-runner-mcp) v2.0.0+ is a working
reference implementation of exactly this — it defaults to this HTTP mode specifically because of
this finding, with a required bearer-token auth (the server refuses to start unauthenticated).

**Wired in and working, not just theoretical**: [`davindermahal/gemini-sandbox`](https://github.com/davindermahal/gemini-sandbox)
exists specifically to test this toolkit against a real project, and its `bin/mcp-up` /
`bin/mcp-down` / `bin/mcp-status` (also reachable as `make mcp-up` etc. there) are a complete,
verified reference for wiring this into any project that uses this toolkit — per-developer token
generation, process lifecycle management (including two real bugs found and fixed by actually
running it repeatedly: `npx`-launched processes need process-group tracking, not `$!`, and
"started" needs to mean the port is actually accepting connections, not just that a process
exists — see that repo's `.ai/system.md` for the full detail), and the `makeRunner` entry in
`.gemini/settings.json.tmpl`. Copy that pattern into your own project's `.gemini/` directory and
`Makefile`. Not currently baked into this toolkit's own `install.sh`/`merge-settings.js` (those
register global, always-on `stdio` servers — `ai-intake-mcp`, `chrome-devtools-mcp` — spawned
fresh inside each sandbox session; `make-runner-mcp` is architecturally different, a persistent
per-project process with its own port and token, which is why it's a per-project setup rather than
a global toolkit registration).

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
- `bin/gemini-sandbox` — the wrapper: sets `GEMINI_SANDBOX=docker`, `GEMINI_SANDBOX_IMAGE`, and
  `SANDBOX_MOUNTS` (only ever non-empty for the local-dev override or an admin policy dir, if
  present — deliberately no docker.sock mount), then execs `gemini`.
- `env.example` / `env` (gitignored, per-machine) — `AI_INTAKE_MCP_DIR` and
  `AI_INTAKE_DOCUMENTATION_MCP_DIR`, the local-dev override described above. Optional.
- `install.sh` — checks prerequisites and environment, builds the image, and wires everything
  above into place.
- `merge-settings.js` — the actual `mcpServers` registration logic install.sh runs; edit this to
  add, remove, or change a registered server.
- `debug.sh` / `debug-live.sh` — see [Troubleshooting](#troubleshooting) above.
