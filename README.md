# gemini-sandbox-toolkit

A shared Gemini CLI Docker sandbox, usable from any project on any of your machines — one image,
one wrapper command, one set of MCP server registrations, instead of copying sandbox files into
every repo.

Full background and the source-cited reasoning behind every decision here:
[davindermahal/gemini-sandbox](https://github.com/davindermahal/gemini-sandbox), particularly
`.ai/guides/gemini-docker-sandbox-mcp.md` Section 6.

## Requirements

Docker (running, and your user in the `docker` group), Node.js, and `gemini-cli` already
installed (`npm install -g @google/gemini-cli`). `install.sh` checks for all of these up front and
exits with a clear message if any are missing, rather than failing partway through.

## Install

```bash
git clone https://github.com/davindermahal/gemini-sandbox-toolkit ~/.gemini-sandbox
cd ~/.gemini-sandbox
./install.sh
```

What it does:

1. **Checks for a conflicting environment first.** If you've tried setting up a Gemini sandbox by
   hand before (on this machine or another), you may have `GEMINI_SANDBOX_IMAGE`,
   `SANDBOX_FLAGS`, etc. exported somewhere — a stray `SANDBOX_FLAGS` with its own docker.sock
   mount will collide with this toolkit's own mount (Docker's "Duplicate mount point" error), and
   a stray `GEMINI_SANDBOX_IMAGE` will make plain `gemini` (with `GEMINI_SANDBOX` also set from an
   old rc file) silently use an old image instead of this one. The installer reports both the
   currently-exported environment and matching `export` lines in your shell rc files — it doesn't
   edit them for you, just tells you what to remove.
2. **Builds the image** (`gemini-sandbox:latest`), pinned to *your* installed `gemini-cli`
   version automatically (`gemini --version`) — not hardcoded, so this works correctly across
   machines on different CLI versions, and after you upgrade `gemini-cli` (just re-run
   `install.sh`).
3. **Symlinks `bin/gemini-sandbox` into `~/.local/bin`.**
4. **Registers MCP servers globally** in `~/.gemini/settings.json` — `chrome-devtools-mcp`
   always, `ai-intake-mcp` if you set `AI_INTAKE_MCP_DIR` in `env` (copy `env.example` to `env`
   first, or just leave it unset if you don't use that server). This **merges** into your existing
   settings rather than overwriting them, and backs up the original once, to
   `~/.gemini/settings.json.pre-gemini-sandbox-install`, the first time it runs.

Safe to re-run any time — every step is idempotent.

## Use

From any project directory:

```bash
gemini-sandbox -s -p "run make unit-test"
```

Plain `gemini` (no wrapper) stays unsandboxed — `gemini-sandbox` is the opt-in, not a global
default. Gemini auto-mounts whatever directory you run it from, so this same command works
against any project without any per-project setup.

## Updating on a machine where it's already installed

```bash
cd ~/.gemini-sandbox
git pull
./install.sh
```

## Files

- `sandbox.Dockerfile` — the image: Docker CLI + compose plugin (for Docker-outside-of-Docker),
  a second Node runtime for MCP servers needing a newer version than the sandbox's bundled one,
  Chromium + `chrome-devtools-mcp`.
- `bin/gemini-sandbox` — the wrapper: sets `GEMINI_SANDBOX=docker`, `GEMINI_SANDBOX_IMAGE`, and
  `SANDBOX_MOUNTS` (docker.sock, plus `ai-intake-mcp` if configured), then execs `gemini`.
- `env.example` / `env` (gitignored, per-machine) — currently just `AI_INTAKE_MCP_DIR`.
- `install.sh` — checks prerequisites and environment, builds the image, and wires everything
  above into place.
