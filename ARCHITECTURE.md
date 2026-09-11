# Architecture: how the pieces fit together

This is the "explain it to a new teammate" doc. `README.md` documents each command in isolation;
this doc explains why there are two fundamentally different kinds of MCP server here, how each one
gets from "a version tag on GitHub/npm" to "a tool the model can call," and where to look when
something doesn't update the way you'd expect.

If you only remember one thing from this doc: **this toolkit manages two categories of MCP server
that behave nothing alike**, and most confusion (including "why isn't my MCP server updating?")
comes from applying one category's mental model to the other.

## The two categories

| | Image-baked (stateless) | `make-runner-mcp` (stateful) |
|---|---|---|
| **Servers** | `chrome-devtools-mcp`, `ai-intake-mcp`, `ai-intake-documentation-mcp` | `make-runner-mcp` only |
| **Lives** | Inside the `gemini-sandbox:latest` Docker image, spawned fresh each session | A standalone host process, one per project, running for as long as you leave it |
| **Registered in** | `~/.gemini/settings.json` — global, written once by `install.sh` | The **current project's own** `.gemini/settings.json` — written by `bin/gemini-sandbox` on *every* invocation |
| **Version pin lives in** | `sandbox.Dockerfile`, as `ARG ..._VERSION=x.y.z` | `bin/gemini-sandbox-mcp-up`, as `MAKE_RUNNER_MCP_VERSION=vX.Y.Z` |
| **Version source** | npm registry | A GitHub release tag (not published to npm at all) |
| **To pick up a new version** | `make upgrade-mcps` (bumps the pin, rebuilds the image, re-registers) | Bump the pin, **then separately** cycle every project's running instance (see below) |
| **Why it's opt-out vs. opt-in** | Always on — safe by design: no standing host access, scoped to one session | Explicit opt-in per project (`gemini-sandbox-mcp-up`) — a different risk class, see below |

Why the split exists: `chrome-devtools-mcp`/`ai-intake-mcp`/`ai-intake-documentation-mcp` are
stateless and project-agnostic. They're spawned fresh inside the sandbox container each session and
exit when the session ends — one global registration, done once at install time, correctly serves
every project you ever run `gemini-sandbox` from. `make-runner-mcp` can't work that way: it needs
real Docker access to run a project's `make` targets, and giving the *sandbox container* Docker
access would be root-equivalent host access handed to a shared container that also runs the model's
native shell tool — see README's
["Docker access for your project's own containers"](README.md#docker-access-for-your-projects-own-containers)
for the full reasoning. So instead, `make-runner-mcp` runs **outside** the sandbox, as its own
process with normal host Docker access, reachable by the sandboxed session only over the network.
That's a fundamentally different lifecycle — one long-lived process per project instead of "spawned
fresh, every session, everywhere" — which is why it needs its own registration mechanism, its own
state, and its own (currently manual) update procedure.

## Walking through `gemini-sandbox -s`

```
you type: gemini-sandbox -s -p "..."
              │
              ▼
    bin/gemini-sandbox (a symlink at ~/.local/bin/gemini-sandbox, installed by install.sh)
              │
              ├─ sets GEMINI_SANDBOX=docker, GEMINI_SANDBOX_IMAGE=gemini-sandbox:latest
              │  (opt-in per invocation — plain `gemini` never gets sandboxed)
              │
              ├─ checks: is a make-runner-mcp process already running for THIS project?
              │  (keyed by this project's real path, via bin/mcp-runner-lib.sh)
              │      • yes → writes/updates this project's .gemini/settings.json
              │              mcpServers.makeRunner entry (merge-project-settings.js)
              │      • had one before, now dead → prints a note, prunes the stale entry
              │      • never used here, but a Makefile exists → prints a one-line hint
              │
              └─ exec gemini "$@"
                     │
                     ▼
            gemini launches its sandbox container from gemini-sandbox:latest,
            mounting your project's cwd automatically (gemini's own behavior)
                     │
                     ▼
            Inside the container, gemini reads BOTH:
              • ~/.gemini/settings.json   (global — chrome-devtools, ai-intake, ai-intake-documentation)
              • <project>/.gemini/settings.json   (project-local — makeRunner, if it was set above)
            and merges them, then spawns/connects each registered MCP server.
```

The global servers are spawned as `stdio` subprocesses *inside* the container — they only ever
exist for that one session. The `makeRunner` entry, if present, is an `http` registration pointing
at `http://host.docker.internal:<port>/mcp` with a bearer token — the sandboxed session reaches out
over the network to a process that was already running on the host *before* this session started.

## The `make-runner-mcp` lifecycle, in detail

```
cd your-project
gemini-sandbox-mcp-up
```

1. Computes a state directory for this project: `~/.gemini-sandbox-mcp-runner/<sha256-of-real-path>/`
   (a hash, not a mangled path — see `bin/mcp-runner-lib.sh`'s comment on why). This is where the
   port, auth token, pid, and log for *this project's* instance live. It's deliberately outside
   this toolkit's own git working tree — state isn't source.
2. If nothing's running yet: picks a free port, generates (or reuses) a random auth token, then
   launches, under `setsid` (so the whole process tree can be killed as one group later):
   ```
   npx -y github:davindermahal/make-runner-mcp#$MAKE_RUNNER_MCP_VERSION
   ```
   with `PROJECT_DIR`, `MCP_HTTP_TOKEN`, `MCP_HTTP_PORT` set in its environment.
3. Polls the port until it's actually accepting connections (not just "the process exists" — `npx`
   itself does a real network round-trip resolving the GitHub ref before `make-runner-mcp` even
   starts, which can take several seconds uncached).
4. Tells you it's ready. This process **keeps running** — in the background, detached from your
   terminal — until you explicitly stop it.

```
gemini-sandbox            # writes this project's makeRunner registration, then runs gemini
gemini-sandbox-mcp-status # "running (pgid ..., port ...)" or "not running"
gemini-sandbox-mcp-log    # tail this project's log (-f to follow, -n N for more lines)
gemini-sandbox-mcp-down   # kills the whole process group, leaves port/token on disk for reuse
```

All four are scoped to the current project (cwd), same as `-up` itself. When you don't know (or
don't want to `cd` into) the specific project at fault — debugging "something's stuck," or wanting
a clean slate across everything this machine has ever started — two more commands work across every
project's state directory at once, without needing to be run from inside any of them:

```
gemini-sandbox-mcp-list       # every project ever started here, running or not, with port/pgid
gemini-sandbox-mcp-down-all   # force-stops all of them, same TERM-then-KILL logic as -down
```

Two projects running this simultaneously don't collide — distinct ports and tokens, one project's
token is rejected against another's endpoint.

## Why "updating make-runner-mcp" is a two-step process

Because it's a long-lived background process (not spawned fresh per session like the image-baked
servers), **there are two separate things that both have to happen**, and it's easy to do only one
and assume you're done:

1. **Bump the pin** — `bin/gemini-sandbox-mcp-up`'s `MAKE_RUNNER_MCP_VERSION=` line needs to name
   the new tag. Do this with `make check-make-runner-mcp-version` / `make bump-make-runner-mcp-version`
   (or `make upgrade-mcps`, which now does this alongside the npm-based packages). This step alone
   changes nothing for a project that already has an instance running — it only affects the *next*
   `gemini-sandbox-mcp-up` anywhere.
2. **Cycle every project's running instance** — the old process doesn't notice the pin changed; it
   just keeps running the code it started with, indefinitely:
   ```bash
   cd your-project
   gemini-sandbox-mcp-down
   gemini-sandbox-mcp-up
   ```
   This has to be repeated per project directory that has one running — this Makefile/toolkit has
   no registry of which projects currently have a live instance, only `~/.gemini-sandbox-mcp-runner/`'s
   contents (`ls` it, or run `gemini-sandbox-mcp-status` from each project you remember using it in).

Skipping step 2 is the most common way this looks like "it's not updating" when the pin was, in
fact, bumped correctly.

## Why `make upgrade-mcps` can't reach `make-runner-mcp` the same way

The image-baked packages' check/bump mechanism (`make check-mcp-versions`) works by asking the npm
registry (`npm view <package> version`) what the latest published version is. `make-runner-mcp`
isn't published to npm at all — it's deliberately GitHub-tag-distributed (see its own repo's
`CLAUDE.md` "Distribution plan": a public repo, `npx github:owner/repo#vX.Y.Z`, so pulling a new
version is always a deliberate, visible tag bump, never an unpinned branch reference that could
silently change on everyone's machine with a bad push). So its own check/bump targets
(`check-make-runner-mcp-version` / `bump-make-runner-mcp-version`) ask a different question —
"what's the highest `vX.Y.Z` git tag on that repo?" (`git ls-remote --tags`) — and write the answer
into a different kind of file (a shell script's variable assignment, not a Dockerfile `ARG`).
`make upgrade-mcps` runs both mechanisms together for convenience, but they remain two genuinely
different lookups underneath.

## Where to look when something's wrong

- **An image-baked server (`chrome-devtools`, `ai-intake`, `ai-intake-documentation`) is missing or
  outdated** → check `sandbox.Dockerfile`'s `ARG ..._VERSION` lines, then `make check-mcp-versions`.
  Fix: `make upgrade-mcps`, or `make bump-mcp-versions && ./install.sh`.
- **`makeRunner` isn't showing up in a project's tools at all** → it's not in
  `~/.gemini/settings.json` (that's correct — it's never global). Check
  `<project>/.gemini/settings.json` instead, and confirm an instance is actually running:
  `cd your-project && gemini-sandbox-mcp-status`. If "not running," `gemini-sandbox-mcp-up` first.
- **`makeRunner` is running an old version of `make-runner-mcp`** → this is the two-step process
  above. Check the pin (`make check-make-runner-mcp-version`), bump it if stale
  (`make bump-make-runner-mcp-version`), then cycle the specific project's instance
  (`gemini-sandbox-mcp-down && gemini-sandbox-mcp-up` **in that project's directory**).
- **A `makeRunner` instance is up but behaving wrong** (stale Makefile targets, unexpected errors
  running a target) → `gemini-sandbox-mcp-log` from that project's directory tails its log; add `-f`
  to follow it live while you retry the failing `make` target.
- **Not sure which project's instance is at fault, or want to reset everything** →
  `gemini-sandbox-mcp-list` shows every project this machine has ever started one for (running or
  not, with pgid/port); `gemini-sandbox-mcp-down-all` force-stops all of them in one shot, from
  anywhere — neither needs `cd`-ing into the project first.
- **An MCP server shows `MCP error -32000: Connection closed`** → see README's
  [Troubleshooting](README.md#troubleshooting): `./debug.sh` first (no live model call, tests the
  image/mounts directly), `./debug-live.sh` if that passes but a real `gemini-sandbox -s` session
  still fails.
- **Two different projects seem to be fighting over `make-runner-mcp`** → they shouldn't be — each
  gets its own state directory, port, and token, keyed by that project's real (symlink-resolved)
  path. If something looks cross-wired, compare `cat <state-dir>/project-dir` across the
  directories under `~/.gemini-sandbox-mcp-runner/` against the project paths you actually expect.

## Files, mapped to the categories above

- `sandbox.Dockerfile`, `Makefile`'s `MCP_PACKAGES`/`check-mcp-versions`/`bump-mcp-versions` /
  `check-better-sqlite3`/`rebuild-better-sqlite3`, `merge-settings.js` → the image-baked category.
- `bin/gemini-sandbox-mcp-up`/`-down`/`-status`/`-log`/`-list`/`-down-all`, `bin/mcp-runner-lib.sh`,
  `merge-project-settings.js`, `Makefile`'s `check-make-runner-mcp-version`/
  `bump-make-runner-mcp-version` → the `make-runner-mcp` category.
- `bin/gemini-sandbox` → the entry point that touches both: sets the sandbox env vars every
  invocation needs, and performs the `make-runner-mcp` discovery/registration step described above,
  before handing off to the real `gemini` binary.
- `install.sh` → one-time (well, safe-to-re-run) setup: builds the image, symlinks the `bin/`
  scripts onto `PATH`, registers the global servers. Does **not** touch any project-local
  `.gemini/settings.json` — that only ever happens via `bin/gemini-sandbox` itself, per-project, on
  demand.
- `env`/`env.example` → local-dev override for iterating on `ai-intake-mcp`/
  `ai-intake-documentation-mcp` from a local clone instead of the pinned published version. Has no
  equivalent for `make-runner-mcp` today (see the [Local-dev override](README.md#local-dev-override-iterating-on-either-server-without-publishing)
  section in the README for what exists).
