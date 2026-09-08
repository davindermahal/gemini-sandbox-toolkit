#!/usr/bin/env node
// Sets or prunes ONLY the mcpServers.makeRunner key of a project's own .gemini/settings.json,
// preserving every other key byte-for-byte. Unlike merge-settings.js (which owns the GLOBAL
// ~/.gemini/settings.json entirely, written once at install time, since chrome-devtools-mcp/
// ai-intake-mcp are stateless and project-agnostic), this runs on EVERY `gemini-sandbox`
// invocation against an ARBITRARY project's file -- one that may already have its own
// hand-authored MCP servers, tool policy, or other settings that must survive untouched. Called
// by bin/gemini-sandbox, not meant to be run directly.
//
// Env vars:
//   MCP_RUNNER_MODE            "set" or "prune"
//   MCP_RUNNER_SETTINGS_PATH   absolute path to the project's .gemini/settings.json
//   MCP_RUNNER_URL             (mode "set" only) the makeRunner server's URL
//   MCP_RUNNER_TOKEN           (mode "set" only) the bearer token
//
// Mode "set": registers/updates the makeRunner entry -- called when an instance is running for
// this project.
// Mode "prune": removes the makeRunner entry if present, otherwise a true no-op (no file created,
// no write) -- called when no instance is running, so a project that has never used this feature
// is never touched at all, and a project that used to have one registered doesn't keep a
// permanently "Connection closed" entry after gemini-sandbox-mcp-down.
//
// Writes atomically (temp file + rename in the same directory) since two `gemini-sandbox`
// invocations in the same project directory could race on this file.

const fs = require("fs");
const path = require("path");

const mode = process.env.MCP_RUNNER_MODE;
const settingsPath = process.env.MCP_RUNNER_SETTINGS_PATH;

if (mode !== "set" && mode !== "prune") {
  console.error(`merge-project-settings.js: invalid MCP_RUNNER_MODE '${mode}' (expected 'set' or 'prune')`);
  process.exit(1);
}
if (!settingsPath) {
  console.error("merge-project-settings.js: MCP_RUNNER_SETTINGS_PATH is required");
  process.exit(1);
}

let settings = null;
if (fs.existsSync(settingsPath)) {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
}

if (mode === "prune") {
  if (!settings || !settings.mcpServers || !("makeRunner" in settings.mcpServers)) {
    process.exit(0); // nothing to do -- keep zero-impact-when-unused true
  }
  delete settings.mcpServers.makeRunner;
} else {
  settings = settings || {};
  settings.mcpServers = settings.mcpServers || {};
  settings.mcpServers.makeRunner = {
    url: process.env.MCP_RUNNER_URL,
    type: "http",
    headers: { Authorization: `Bearer ${process.env.MCP_RUNNER_TOKEN}` },
  };
}

fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
const tmpPath = `${settingsPath}.tmp.${process.pid}`;
fs.writeFileSync(tmpPath, JSON.stringify(settings, null, 2) + "\n");
fs.renameSync(tmpPath, settingsPath);
