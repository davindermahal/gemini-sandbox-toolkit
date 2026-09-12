#!/usr/bin/env bash
# Shared functions for gemini-sandbox-mcp-up/down/status and bin/gemini-sandbox's own discovery
# step. Sourced, never executed directly.
#
# What this manages: per-project state for a persistent make-runner-mcp process (see
# gemini-sandbox/.ai/guides/gemini-docker-sandbox-mcp.md Section 0, and
# gemini-sandbox/bin/mcp-up/mcp-down/mcp-status for the single-project version this generalizes).
# Unlike chrome-devtools-mcp/ai-intake-mcp (stateless, spawned fresh inside the sandbox each
# session, one global registration correctly serves every project), make-runner-mcp is a
# persistent, host-side process scoped to ONE project -- it needs its own port and auth token so
# two different projects' instances don't collide, hence the keyed state directory below rather
# than anything global.

# Root directory for all per-project make-runner-mcp state. Deliberately NOT nested under
# $TOOLKIT_DIR (wherever this toolkit repo happens to be cloned, e.g. ~/.gemini-sandbox) -- state
# isn't source, it shouldn't live inside a git working tree needing a permanent .gitignore
# exception, and it shouldn't silently relocate if the toolkit is ever re-cloned somewhere else.
MCP_RUNNER_STATE_ROOT="$HOME/.gemini-sandbox-mcp-runner"

# Computes the state-directory key for a project directory: a hash of its canonicalized
# (symlink-resolved) absolute path, not a mangled version of the path itself. Mangling (e.g.
# "/" -> "-") has real, non-obvious collision cases -- /home/user/foo-bar and /home/user/foo/bar
# can mangle toward similar-looking names, and a naive transform isn't provably collision-free. A
# hash is collision-safe by construction; the tradeoff (an opaque directory name) is paid back by
# the project-dir file each state directory also holds (see mcp_runner_state_dir below) for
# debugging/reverse-lookup. Canonicalizing first matters for the same reason TOOLKIT_DIR and this
# script's own callers already resolve symlinks before computing paths (see bin/gemini-sandbox's
# and install.sh's own readlink -f comments) -- two different-looking paths to the same real
# project directory must produce the same key.
mcp_runner_project_key() {
  local project_dir
  project_dir="$(cd "$1" && pwd -P)"
  printf '%s' "$project_dir" | sha256sum | cut -c1-16
}

# Absolute path to a project's state directory (may not exist yet -- callers create it on first
# use). Holds: project-dir (plaintext canonical path, debugging/reverse-lookup only), port, token,
# pid (a process GROUP id, see mcp_runner_is_alive below), log.
mcp_runner_state_dir() {
  echo "$MCP_RUNNER_STATE_ROOT/$(mcp_runner_project_key "$1")"
}

# True (exit 0) if a make-runner-mcp process GROUP is alive for the given state directory. Checks
# the process *group* (a negative PID), not a single PID -- verified directly (ps --forest) that
# `npx -y ...` is not one process (true of both the GitHub-tag spec this originally shipped with
# and the npm spec it uses now -- re-verified against the npm one when make-runner-mcp moved to
# npm): it's npm-exec -> `sh -c 'make-runner-mcp'` -> the real `node .../make-runner-mcp`, three
# levels deep, and which level survives varies (observed: the top-level npm-exec process exits on
# its own once package resolution is already cached locally, orphaning the real server two levels
# down where a plain `$!`-tracked PID can't find it -- this is a real bug that was hit and fixed
# in gemini-sandbox/bin/mcp-up, generalized here). Launching
# under `setsid` (gemini-sandbox-mcp-up) makes the launched process its own session/process-group
# leader, and everything it forks inherits that same group, so checking/killing the *group*
# reliably reaches all of them regardless of which level ends up being the "top" one -- the group
# persists as long as any member is alive, even after its original leader process exits.
mcp_runner_is_alive() {
  local state_dir="$1"
  [[ -f "$state_dir/pid" ]] && kill -0 "-$(cat "$state_dir/pid")" 2>/dev/null
}

# Picks a free TCP port by asking the OS for one (bind port 0, read back the assigned port, close
# immediately) rather than a fixed or deterministic-hash-derived port -- both of those risk
# collisions between concurrently-running projects for no real benefit, since nothing in this
# design ever exposes the port number to a human; it's consumed only by the rendered
# .gemini/settings.json. Node is already a hard prerequisite for this toolkit (install.sh checks
# for it), so this adds no new dependency. Narrow TOCTOU race (something else could grab this
# exact port before make-runner-mcp itself binds it) is acceptable: the readiness poll in
# gemini-sandbox-mcp-up already treats "started" as "actually reachable," so a lost race just
# surfaces as a normal, already-handled startup failure with the log tail printed.
mcp_runner_pick_free_port() {
  node -e '
    const net = require("net");
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => console.log(port));
    });
  '
}
