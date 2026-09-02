#!/usr/bin/env bash
# One-time (and re-runnable) setup for the shared Gemini CLI sandbox toolkit.
#
# What this does:
#   1. Checks for prerequisites and warns about environment conflicts from an earlier manual
#      sandbox setup, if any (stray SANDBOX_FLAGS / GEMINI_SANDBOX_IMAGE etc).
#   2. Builds the sandbox image (docker CLI + compose, a second Node runtime, Chromium,
#      chrome-devtools-mcp), tagged gemini-sandbox:latest, pinned to your installed CLI's version.
#   3. Puts the `gemini-sandbox` wrapper on your PATH via ~/.local/bin.
#   4. Registers chrome-devtools-mcp (and ai-intake-mcp, if env is configured) in your global
#      ~/.gemini/settings.json -- merged in, existing settings are preserved. A one-time backup
#      is written to ~/.gemini/settings.json.pre-gemini-sandbox-install if one doesn't already
#      exist.
#
# Safe to re-run any time (e.g. after editing sandbox.Dockerfile or env, or after a gemini-cli
# upgrade -- re-running repins the sandbox image to your current CLI version).
set -euo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
GEMINI_SETTINGS="$HOME/.gemini/settings.json"

# --- 1. Prerequisites ------------------------------------------------------------------------
missing=()
for cmd in docker node gemini getent; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing required command(s): ${missing[*]}" >&2
  echo "This toolkit needs Docker, Node.js, and gemini-cli (npm install -g @google/gemini-cli) already installed." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not usable (daemon not running, or you're not in the docker group)." >&2
  echo "Check: docker ps" >&2
  exit 1
fi

# --- 2. Environment conflict check ------------------------------------------------------------
# Two known, previously-hit failure modes, both from an EARLIER manual sandbox setup attempt
# still lingering somewhere: a stray SANDBOX_FLAGS with its own docker.sock mount collides with
# this wrapper's own (Docker's "Duplicate mount point" error), and a stray GEMINI_SANDBOX_IMAGE
# pointing at a different, older image (this wrapper always overrides it for its OWN invocations,
# but plain `gemini` with GEMINI_SANDBOX also set from an rc file would silently use the stale
# image instead of this toolkit's). This script can't unset variables in the shell that invoked
# it (a subprocess can't reach back into its parent's environment) or in rc files it hasn't been
# told to edit -- so it reports what it finds instead of guessing at a fix.
echo "==> Checking for conflicting environment from an earlier manual sandbox setup"
conflict_vars=(GEMINI_SANDBOX GEMINI_SANDBOX_IMAGE SANDBOX_MOUNTS SANDBOX_FLAGS)
found_any=0
for var in "${conflict_vars[@]}"; do
  if [[ -n "${!var:-}" ]]; then
    echo "    currently exported: $var=${!var}"
    found_any=1
  fi
done
rc_hits=()
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
  [[ -f "$rc" ]] || continue
  while IFS= read -r line; do
    rc_hits+=("$rc: $line")
  done < <(grep -nE "export[[:space:]]+(GEMINI_SANDBOX|GEMINI_SANDBOX_IMAGE|SANDBOX_MOUNTS|SANDBOX_FLAGS)=" "$rc" 2>/dev/null || true)
done
if [[ ${#rc_hits[@]} -gt 0 ]]; then
  found_any=1
  echo "    found in shell rc files:"
  printf '      %s\n' "${rc_hits[@]}"
fi
if [[ "$found_any" -eq 1 ]]; then
  echo "    This toolkit's wrapper (bin/gemini-sandbox) sets GEMINI_SANDBOX, GEMINI_SANDBOX_IMAGE,"
  echo "    and SANDBOX_MOUNTS itself on every run -- lines above won't break \`gemini-sandbox\`"
  echo "    specifically, but SANDBOX_FLAGS can still collide with its docker.sock mount, and any"
  echo "    of these left exported will affect plain \`gemini\` (e.g. an old GEMINI_SANDBOX_IMAGE"
  echo "    pointing at a different image). Recommended: remove the export lines above from your"
  echo "    rc file(s) and open a fresh shell -- editing a rc file alone doesn't unset a variable"
  echo "    already exported in your CURRENT shell."
else
  echo "    none found -- clean."
fi

# --- 3. Build the image, pinned to your installed CLI's version -------------------------------
GEMINI_CLI_VERSION="$(gemini --version 2>/dev/null | tr -d '[:space:]')"
echo "==> Building gemini-sandbox:latest (base image pinned to your gemini-cli version: $GEMINI_CLI_VERSION)"
# Run from inside TOOLKIT_DIR with a *relative* -f, not an absolute path -- some BuildKit versions
# fail to resolve an absolute Dockerfile path that's inside the build context ("failed to read
# dockerfile: open sandbox.Dockerfile: no such file or directory", despite the file existing),
# because BuildKit re-resolves -f relative to the context internally. Relative avoids the
# ambiguity entirely and works the same on versions where the absolute form happened to be fine.
(
  cd "$TOOLKIT_DIR"
  docker build \
    --build-arg DOCKER_GID="$(getent group docker | cut -d: -f3)" \
    --build-arg GEMINI_CLI_VERSION="$GEMINI_CLI_VERSION" \
    -t gemini-sandbox:latest \
    -f sandbox.Dockerfile \
    .
)

# --- 4. Install the wrapper ---------------------------------------------------------------------
echo "==> Installing bin/gemini-sandbox to $BIN_DIR"
mkdir -p "$BIN_DIR"
ln -sf "$TOOLKIT_DIR/bin/gemini-sandbox" "$BIN_DIR/gemini-sandbox"
if ! command -v gemini-sandbox >/dev/null 2>&1; then
  echo "WARNING: $BIN_DIR is not on your PATH. Add this to your shell rc:" >&2
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
fi

if [[ ! -f "$TOOLKIT_DIR/env" ]]; then
  cp "$TOOLKIT_DIR/env.example" "$TOOLKIT_DIR/env"
  echo "==> Wrote $TOOLKIT_DIR/env from the template -- edit it to set AI_INTAKE_MCP_DIR (or leave blank if you don't use it)."
fi
# shellcheck disable=SC1090
source "$TOOLKIT_DIR/env" 2>/dev/null || true

# --- 5. Register MCP servers globally, merging rather than overwriting -------------------------
echo "==> Registering MCP servers in $GEMINI_SETTINGS"
mkdir -p "$(dirname "$GEMINI_SETTINGS")"
if [[ -f "$GEMINI_SETTINGS" && ! -f "$GEMINI_SETTINGS.pre-gemini-sandbox-install" ]]; then
  cp "$GEMINI_SETTINGS" "$GEMINI_SETTINGS.pre-gemini-sandbox-install"
  echo "    (backed up your existing settings to $GEMINI_SETTINGS.pre-gemini-sandbox-install)"
fi

AI_INTAKE_MCP_DIR="${AI_INTAKE_MCP_DIR:-}" GEMINI_SETTINGS_PATH="$GEMINI_SETTINGS" node -e '
const fs = require("fs");
const path = process.env.GEMINI_SETTINGS_PATH;
let settings = {};
if (fs.existsSync(path)) {
  settings = JSON.parse(fs.readFileSync(path, "utf8"));
}
settings.mcpServers = settings.mcpServers || {};
settings.mcpServers["chrome-devtools"] = {
  command: "chrome-devtools-mcp",
  args: [
    "--headless",
    "--executable-path", "/usr/bin/chromium",
    "--chrome-arg=--no-sandbox",
    "--chrome-arg=--disable-dev-shm-usage",
  ],
};
const aiIntakeDir = process.env.AI_INTAKE_MCP_DIR;
if (aiIntakeDir && fs.existsSync(aiIntakeDir)) {
  settings.mcpServers["ai-intake"] = {
    command: "/usr/bin/node",
    args: [`${aiIntakeDir}/dist/index.js`],
  };
}
fs.writeFileSync(path, JSON.stringify(settings, null, 2) + "\n");
console.log("    registered:", Object.keys(settings.mcpServers).join(", "));
'

echo ""
echo "==> Done. From any project directory:"
echo "      gemini-sandbox -s -p \"...\""
echo "    (plain \"gemini\" stays unsandboxed -- this wrapper is the opt-in.)"
