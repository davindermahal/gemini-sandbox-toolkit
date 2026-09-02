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

PROMPT="${1:-List the MCP tools available to you, then call one cheap read-only tool from each connected MCP server and report exactly what each returns.}"

echo "==> Running a real, --debug gemini-sandbox -s session (uses one live model turn against your configured gemini auth; timeout ${TIMEOUT}s)"
echo "    Prompt: $PROMPT"
timeout "$TIMEOUT" "$TOOLKIT_DIR/bin/gemini-sandbox" -s -d --skip-trust -y -p "$PROMPT" > "$LOG" 2>&1
EXIT_CODE=$?

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
