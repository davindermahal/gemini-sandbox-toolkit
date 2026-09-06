# Getting `ai-intake` and `documentation-mcp` running — a guide for teammates

Two ways to get these two MCP servers working with `gemini`. Pick whichever fits — you don't need
to use `gemini-sandbox-toolkit` to use these servers, and you don't need these servers to use the
sandbox. They're independent.

## Option A: use `gemini-sandbox-toolkit` (recommended if you're open to it)

This is the easiest path — both servers are pre-installed into the sandbox image, nothing to
configure.

```bash
git clone https://github.com/davindermahal/gemini-sandbox-toolkit ~/.gemini-sandbox
cd ~/.gemini-sandbox
./install.sh
```

Then from any project directory:

```bash
gemini-sandbox -s -p "..."
```

That's it — `ai-intake` and `ai-intake-documentation` are already registered and working. See that
repo's own README for full details, prerequisites (Docker, Node, `gemini-cli`), and
troubleshooting (`./debug.sh`, `./debug-live.sh`).

If you hit a problem, jump straight to that README's Troubleshooting section rather than
duplicating it here.

## Option B: run them directly, without the sandbox

If you don't want Docker or the sandbox at all, both servers are published npm packages and can be
registered directly against your own `gemini`:

```bash
gemini mcp add --scope user ai-intake npx -y @davindermahal/ai-intake-mcp@0.1.1
gemini mcp add --scope user documentation-mcp npx -y @davindermahal/documentation-mcp@0.2.0
```

(Versions above are current as of 2026-09-06 — check `npm view @davindermahal/ai-intake-mcp
version` / `npm view @davindermahal/documentation-mcp version` for the latest, or drop the version
pin entirely to always get the newest release.)

### Prerequisites for Option B

- **Node.js >=24.** Both packages require it. Check with `node --version`.
- **A working C/C++ build toolchain**, for a one-time native-module compile the first time you run
  `ai-intake-mcp` (it depends on `better-sqlite3` and `keytar`, neither of which currently ships a
  prebuilt binary for Node 24 on any platform — this was checked directly against their GitHub
  releases). On macOS: `xcode-select --install`. On Linux, `build-essential` (Debian/Ubuntu) or
  your distro's equivalent is usually already there. This compile happens once, on first launch,
  not on every session.
- Jira credentials for `ai-intake-mcp` — see that repo's own README for the env vars it expects.

### If it doesn't connect

The most common cause is the Node version above being wrong at the moment `gemini` launches the
server — if you have multiple Node versions installed (nvm, asdf, etc.), make sure the one active
in your shell when `gemini` starts is >=24. A generic `MCP error -32000: Connection closed` with no
more specific reason is the usual symptom of this exact mismatch.

## What about a shared/remote server, so nobody has to install anything?

Not available yet. Both servers currently only support stdio (a local process per client) — a
remote HTTP option, where one person runs a single long-lived instance and everyone else just
points at a URL, is planned but not built. If you want to track that:

- `ai-intake-mcp`: `.ai/plans/draft/http-transport-and-v2-sdk-migration.md` in that repo
- `ai-intake-documentation-mcp`: `.ai/plans/draft/2026-09-06-add-optional-http-transport-default-stdio.md` in that repo

Until then, Option A or Option B above are the only ways to run either server.
