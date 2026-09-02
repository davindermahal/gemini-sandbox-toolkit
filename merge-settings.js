#!/usr/bin/env node
// Registers this toolkit's MCP servers into the global ~/.gemini/settings.json, merging with
// whatever is already there rather than overwriting it. Run by install.sh (via `node
// merge-settings.js`, with GEMINI_SETTINGS_PATH and AI_INTAKE_MCP_DIR set in its environment),
// not meant to be run directly.
//
// To add a new MCP server to this toolkit: add an entry to settings.mcpServers below. This used
// to be embedded as a bash `node -e '...'` single-quoted string in install.sh -- moved to its own
// file after that broke twice from an apostrophe in a comment closing the outer bash string early
// (bash single quotes cannot be escaped). Plain JS file, no bash quoting to fight.

const fs = require("fs");

const settingsPath = process.env.GEMINI_SETTINGS_PATH;
let settings = {};
if (fs.existsSync(settingsPath)) {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
}
settings.mcpServers = settings.mcpServers || {};

// Always registered.
settings.mcpServers["chrome-devtools"] = {
  command: "/usr/local/share/npm-global/bin/chrome-devtools-mcp",
  args: [
    "--headless",
    "--executable-path", "/usr/bin/chromium",
    "--chrome-arg=--no-sandbox",
    "--chrome-arg=--disable-dev-shm-usage",
    // gemini remaps the sandbox container to the raw host UID/GID by default (logs this as
    // "Defaulting to use current user UID/GID") and sets HOME to match the real host home path,
    // so that $HOME/.gemini still resolves to the identity-mounted config -- but that HOME
    // directory only exists inside the container as an auto-vivified, root-owned parent for that
    // one bind-mount target, not otherwise writable. The default Chrome cache dir is
    // $HOME/.cache, which lands exactly there and fails EACCES on mkdir -- confirmed directly (a
    // plain `docker run` with an unrecognized --user UID reproduces the same mkdir failure on any
    // HOME-relative path). /tmp is verified writable regardless of UID mapping (sticky bit 777),
    // so give Chrome an explicit profile dir there instead of letting it default under HOME.
    "--user-data-dir=/tmp/chrome-devtools-mcp-profile",
  ],
};

// Conditional: only registered if AI_INTAKE_MCP_DIR is set and actually exists on this host (see
// env.example) -- never overwrites this entry otherwise, even if something else already
// registered "ai-intake" (e.g. that server's own setup docs, run directly against the host).
const aiIntakeDir = process.env.AI_INTAKE_MCP_DIR;
if (aiIntakeDir && fs.existsSync(aiIntakeDir)) {
  settings.mcpServers["ai-intake"] = {
    command: "/usr/bin/node",
    args: [`${aiIntakeDir}/dist/index.js`],
  };
}

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
console.log("    registered:", Object.keys(settings.mcpServers).join(", "));
