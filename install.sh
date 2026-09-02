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

# readlink -f resolves symlinks first -- see bin/gemini-sandbox's comment on the same line for
# why this matters (a real bug hit here: without it, TOOLKIT_DIR resolves wrong when this script
# is invoked through a symlink rather than its real path).
TOOLKIT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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
# Previously-hit failure modes, all from an EARLIER manual sandbox setup attempt still lingering
# somewhere: a stray SANDBOX_FLAGS with its own docker.sock mount collides with this wrapper's own
# (Docker's "Duplicate mount point" error); a stray GEMINI_SANDBOX_IMAGE points at a different,
# older image (this wrapper overrides it for its OWN invocations, but plain `gemini` with
# GEMINI_SANDBOX also set from an rc file would silently use the stale image instead); and
# DOCKER_HOST/DOCKER_CONTEXT/DOCKER_BUILDKIT/BUILDX_BUILDER can point `docker build` itself at a
# different daemon, context, or builder than expected -- worth surfacing even though this toolkit
# doesn't use any of them, since a stale one from an earlier attempt can make `docker build`
# behave in ways that look like a bug in this script but aren't. This script can't unset variables
# in the shell that invoked it (a subprocess can't reach back into its parent's environment) or in
# rc files it hasn't been told to edit -- so it reports what it finds instead of guessing.
echo "==> Checking for conflicting environment from an earlier manual sandbox setup"
conflict_vars=(GEMINI_SANDBOX GEMINI_SANDBOX_IMAGE SANDBOX_MOUNTS SANDBOX_FLAGS DOCKER_HOST DOCKER_CONTEXT DOCKER_BUILDKIT BUILDX_BUILDER)
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
  done < <(grep -nE "export[[:space:]]+(GEMINI_SANDBOX|GEMINI_SANDBOX_IMAGE|SANDBOX_MOUNTS|SANDBOX_FLAGS|DOCKER_HOST|DOCKER_CONTEXT|DOCKER_BUILDKIT|BUILDX_BUILDER)=" "$rc" 2>/dev/null || true)
done
if [[ ${#rc_hits[@]} -gt 0 ]]; then
  found_any=1
  echo "    found in shell rc files:"
  printf '      %s\n' "${rc_hits[@]}"
fi
if [[ "$found_any" -eq 1 ]]; then
  echo "    This toolkit's wrapper (bin/gemini-sandbox) sets GEMINI_SANDBOX, GEMINI_SANDBOX_IMAGE,"
  echo "    and SANDBOX_MOUNTS itself on every run -- lines above won't break \`gemini-sandbox\`"
  echo "    specifically, but SANDBOX_FLAGS can still collide with its docker.sock mount, a stale"
  echo "    DOCKER_HOST/DOCKER_CONTEXT/BUILDX_BUILDER can point \`docker build\` at an unexpected"
  echo "    daemon or builder, and any of these left exported will affect plain \`gemini\`/\`docker\`"
  echo "    generally. Recommended: remove the export lines above from your rc file(s) and open a"
  echo "    fresh shell -- editing a rc file alone doesn't unset a variable already exported in"
  echo "    your CURRENT shell."
else
  echo "    none found -- clean."
fi
echo "    active docker context: $(docker context show 2>/dev/null || echo '(none / classic)')"
echo "    buildx builder: $(docker buildx inspect 2>/dev/null | awk -F': *' '/^Name:/{print $2; exit}' || echo '(unavailable)')"

# --- 3. Build the image, pinned to your installed CLI's version -------------------------------
GEMINI_CLI_VERSION="$(gemini --version 2>/dev/null | tr -d '[:space:]')"
echo "==> Building gemini-sandbox:latest (base image pinned to your gemini-cli version: $GEMINI_CLI_VERSION)"
# sandbox.Dockerfile has no COPY/ADD -- it never needs any local file besides itself -- so the
# build is piped in via stdin with NO separate build context, rather than `-f sandbox.Dockerfile
# .`. This isn't just a style choice: BuildKit's handling of `-f` against a directory context
# turned out to be version-dependent (confirmed: it failed with "failed to read dockerfile: open
# sandbox.Dockerfile: no such file or directory" on a host running an older buildx/BuildKit, even
# with a relative path, a verified-correct cwd, and a completely clean environment -- two
# different fixes attempting to work around that path-resolution behavior both failed). Piping the
# Dockerfile via stdin removes BuildKit's context-relative dockerfile lookup from the equation
# entirely, rather than trying to satisfy whatever that lookup wants on every BuildKit version.
DOCKER_GID_VAL="$(getent group docker | cut -d: -f3)"
echo "    dockerfile: $TOOLKIT_DIR/sandbox.Dockerfile (piped via stdin, no separate build context needed)"
set -x
docker build \
  --build-arg DOCKER_GID="$DOCKER_GID_VAL" \
  --build-arg GEMINI_CLI_VERSION="$GEMINI_CLI_VERSION" \
  -t gemini-sandbox:latest \
  - < "$TOOLKIT_DIR/sandbox.Dockerfile"
set +x

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

# Logic lives in merge-settings.js, not inline here -- see that file's header comment for why
# (an inline bash single-quoted `node -e '...'` string broke twice from an apostrophe in a
# comment closing the string early; a real .js file has no bash quoting to fight, and is also
# just the more natural place to add a new MCP server registration later).
AI_INTAKE_MCP_DIR="${AI_INTAKE_MCP_DIR:-}" GEMINI_SETTINGS_PATH="$GEMINI_SETTINGS" node "$TOOLKIT_DIR/merge-settings.js"

echo ""
echo "==> Done. From any project directory:"
echo "      gemini-sandbox -s -p \"...\""
echo "    (plain \"gemini\" stays unsandboxed -- this wrapper is the opt-in.)"
