#!/usr/bin/env bash
# Live MCP diagnostic -- unlike debug.sh (isolated docker run, no gemini, no live model call), this
# drives a REAL `gemini-sandbox -s -d` session and extracts each MCP server's actual stderr
# output. This is what actually found the root cause of a real "Connection closed" bug (a
# symlink-resolution bug in the wrapper itself, not an MCP problem at all) -- debug.sh proved the
# image/binaries/mounts were healthy, which was necessary but not sufficient, since it doesn't
# replicate gemini's own process tree, spawn mechanism, or environment construction. Reach for
# this whenever a server is healthy in debug.sh but still fails through a real gemini session.
#
# Makes one real request against whatever account/auth gemini is configured with (a Developer API
# key, a Google account via Code Assist, Vertex AI -- whatever `gemini` itself already uses),
# drawing from that account's own usage/quota, whatever pool that is. debug.sh makes no such
# request at all and should be run first.
set -uo pipefail

TOOLKIT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TIMEOUT="${DEBUG_LIVE_TIMEOUT:-180}"
LOG="$(mktemp /tmp/gemini-sandbox-debug-live.XXXXXX)"
CMD_FILE="$(mktemp)"
trap 'rm -f "$CMD_FILE"' EXIT

PROMPT="${1:-List the MCP tools available to you, then call one cheap read-only tool from each connected MCP server and report exactly what each returns.}"

echo "==> Running a real, --debug gemini-sandbox -s session (uses one live model turn against your configured gemini auth; timeout ${TIMEOUT}s)"
echo "    Prompt: $PROMPT"
# node writes stdout SYNCHRONOUSLY when it's a TTY and ASYNCHRONOUSLY (buffered) otherwise --
# confirmed on this machine: `process.stdout.isTTY` is undefined when redirected to a file, as
# `> "$LOG"` does. A hung/killed process never gets to flush that buffer, so a plain redirect can
# produce a completely empty log even after minutes of real activity -- exactly what happened here
# (exit 137 from --kill-after, zero bytes captured). `script` allocates a pseudo-TTY so gemini
# writes are synchronous and land in the log as they happen, hang or no hang. `-q` suppresses
# script's own start/done banners; `-e`/`--return` makes script exit with the child's real exit
# status (so $? below is still timeout's, e.g. 124/137/0) rather than script's own.
cat > "$CMD_FILE" <<CMDEOF
#!/usr/bin/env bash
exec timeout --kill-after=15 "$TIMEOUT" "$TOOLKIT_DIR/bin/gemini-sandbox" -s -d --skip-trust -y -p "$PROMPT"
CMDEOF
chmod +x "$CMD_FILE"
script -qec "$CMD_FILE" "$LOG" >/dev/null
EXIT_CODE=$?

# Belt-and-suspenders: a SIGKILL to the tracked process (gemini, via `exec` in bin/gemini-sandbox)
# does not necessarily reach its own docker-run child (a separate PID, not in the same process
# group by default), which can leave the sandbox container itself running even after this script
# exits -- confirmed to happen in practice. Force-clean any of this tool's sandbox containers
# unconditionally; they're always meant to be single-use and ephemeral (--rm), so this is safe
# even if it removes one from a different concurrent run.
LEFTOVER="$(docker ps -aq --filter "name=gemini-sandbox-latest-" 2>/dev/null || true)"
if [[ -n "$LEFTOVER" ]]; then
  echo "==> Cleaning up leftover sandbox container(s) (SIGKILL to gemini doesn't reach its own docker-run child):"
  # Its own --rm may already be tearing it down concurrently (a harmless race, not an error) --
  # suppress that specific noise rather than let it look like something went wrong.
  docker rm -f $LEFTOVER 2>&1 | grep -v "is already in progress" | sed 's/^/  /'
fi

echo ""
echo "==> SANDBOX_MOUNTS actually applied (confirms the sandbox itself launched and what's mounted):"
if grep -q "SANDBOX_MOUNTS:" "$LOG"; then
  grep "SANDBOX_MOUNTS:" "$LOG" | sed 's/^/  /'
else
  echo "  (none found -- sandbox may not have launched at all; check the full log)"
fi

echo ""
echo "==> Per-server MCP stderr (the actual reason a server failed, if it did -- this is the"
echo "    thing debug.sh cannot show you, since it never runs the server through gemini itself):"
if grep -q "MCP STDERR" "$LOG"; then
  grep "MCP STDERR" "$LOG" | sed 's/^/  /'
else
  echo "  (none captured)"
fi

echo ""
echo "==> MCP connection lifecycle (successful connects and explicit failures):"
if grep -qE "Registering notification handlers|Connection closed|MCP error|supports tool updates" "$LOG"; then
  grep -E "Registering notification handlers|Connection closed|MCP error|supports tool updates" "$LOG" | sed 's/^/  /'
else
  echo "  (no MCP lifecycle messages found in the log at all)"
fi

echo ""
if [[ $EXIT_CODE -eq 124 ]]; then
  echo "==> Timed out after ${TIMEOUT}s (exit 124). This can be real API/network slowness on this"
  echo "    host unrelated to MCP (gemini does an auth/API round-trip on the host before even"
  echo "    deciding to sandbox -- see the guide's Section 6.7) rather than an MCP problem. Retry"
  echo "    with a longer budget: DEBUG_LIVE_TIMEOUT=300 ./debug-live.sh"
elif [[ $EXIT_CODE -ne 0 ]]; then
  echo "==> gemini exited with code $EXIT_CODE."
fi
echo "==> Full raw log kept at: $LOG"
