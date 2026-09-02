#!/usr/bin/env bash
# Diagnoses MCP server connectivity problems inside the sandbox image without needing `gemini`
# itself or any API quota -- run this when gemini reports something like:
#   error during discovery for MCP server '<name>': MCP error -32000: Connection closed
# and it's unclear whether the problem is in the image itself or in how gemini spawns things.
# Every check below uses plain `docker run` and stdio, the same mechanism gemini's own sandbox
# uses to talk to an MCP server -- so a failure here reproduces the real problem directly.
set -uo pipefail   # not -e: keep going through every check even if one fails, report all of them

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=gemini-sandbox:latest

pass() { echo "  [OK]   $1"; }
fail() { echo "  [FAIL] $1"; }

echo "==> Image"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  pass "$IMAGE exists locally"
else
  fail "$IMAGE not found -- run ./install.sh first"
  exit 1
fi

echo ""
echo "==> Registered MCP servers (\$HOME/.gemini/settings.json)"
if [[ -f "$HOME/.gemini/settings.json" ]]; then
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const servers = s.mcpServers || {};
    const names = Object.keys(servers);
    console.log("  registered:", names.length ? names.join(", ") : "(none)");
    for (const [name, cfg] of Object.entries(servers)) {
      console.log(`  ${name}:`, JSON.stringify(cfg));
    }
  ' "$HOME/.gemini/settings.json"
else
  fail "$HOME/.gemini/settings.json does not exist -- run ./install.sh"
fi

ENV_FILE="$TOOLKIT_DIR/env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

HANDSHAKE='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"debug","version":"0"}}}'

echo ""
echo "==> chrome-devtools-mcp: launch + MCP initialize handshake, inside the actual image"
OUT="$(docker run --rm --entrypoint sh "$IMAGE" -c "
  command -v chrome-devtools-mcp >/dev/null 2>&1 || { echo BINARY_MISSING; exit 1; }
  echo '$HANDSHAKE' | timeout 15 chrome-devtools-mcp --headless --executable-path /usr/bin/chromium --chrome-arg=--no-sandbox --chrome-arg=--disable-dev-shm-usage
  echo EXIT_CODE:\$?
" 2>&1)"
if echo "$OUT" | grep -q '"serverInfo"'; then
  pass "responded correctly"
else
  fail "did not respond with a valid MCP handshake. Full output:"
  echo "$OUT" | sed 's/^/    /'
fi

echo ""
echo "==> ai-intake-mcp: launch + MCP initialize handshake, inside the actual image"
if [[ -z "${AI_INTAKE_MCP_DIR:-}" ]]; then
  echo "  (skipped -- AI_INTAKE_MCP_DIR not set in $ENV_FILE)"
elif [[ ! -d "$AI_INTAKE_MCP_DIR" ]]; then
  fail "AI_INTAKE_MCP_DIR=$AI_INTAKE_MCP_DIR does not exist on this host"
else
  CFG="$HOME/.config/ai-intake-mcp"
  MOUNTS=(-v "$AI_INTAKE_MCP_DIR:$AI_INTAKE_MCP_DIR:ro")
  [[ -d "$CFG" ]] && MOUNTS+=(-v "$CFG:$CFG:ro")
  OUT="$(docker run --rm --entrypoint sh "${MOUNTS[@]}" "$IMAGE" -c "
    test -f '$AI_INTAKE_MCP_DIR/dist/index.js' || { echo DIST_MISSING; exit 1; }
    echo '$HANDSHAKE' | timeout 15 /usr/bin/node '$AI_INTAKE_MCP_DIR/dist/index.js'
    echo EXIT_CODE:\$?
  " 2>&1)"
  if echo "$OUT" | grep -q '"serverInfo"'; then
    pass "responded correctly"
  else
    fail "did not respond with a valid MCP handshake. Full output:"
    echo "$OUT" | sed 's/^/    /'
  fi
fi

echo ""
echo "==> Resources (a process that starts then immediately dies is often OOM-killed --"
echo "    Chrome in particular is memory-hungry, and this is common in constrained containers/VMs)"
echo "  host memory:"
(free -h 2>/dev/null || vm_stat 2>/dev/null || echo "  (unavailable)") | sed 's/^/    /'
echo "  container memory limit (unset/max means no explicit limit):"
docker run --rm --entrypoint sh "$IMAGE" -c \
  'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "(cgroup info unavailable)"' \
  | sed 's/^/    /'
echo "  recent OOM kills on this host (if readable):"
(dmesg 2>/dev/null | grep -i "killed process\|out of memory" | tail -5 || echo "  (dmesg unavailable or not permitted)") | sed 's/^/    /'

echo ""
echo "==> Done. If both MCP checks above say [OK], the image and mounts are fine and the problem"
echo "    is specific to how gemini itself is spawning them -- share this full output either way."
