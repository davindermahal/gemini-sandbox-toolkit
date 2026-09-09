# Shared Gemini CLI sandbox image, usable across every project on this machine.
#
# This file (and the rest of ~/.gemini-sandbox/) originated from and is documented in detail in
# https://github.com/davindermahal/gemini-sandbox -- see that repo's
# .ai/guides/gemini-docker-sandbox-mcp.md for the full source-cited writeup of every decision
# below. This copy is deliberately project-agnostic: nothing here references any one repo.
#
# Built with a plain `docker build` (see install.sh), NOT `BUILD_SANDBOX=1 gemini` -- that
# mechanism only works when gemini-cli itself is a source checkout (`npm link ./packages/cli`
# inside the gemini-cli repo), and refuses to run against a normal `npm install -g
# @google/gemini-cli`. Base image is pinned to match the installed CLI version rather than `FROM
# gemini-cli-sandbox` (the name most docs lead with) -- that tag is only ever produced by the
# source-checkout build path above and doesn't exist for a normal install. install.sh detects
# your installed CLI's version automatically (`gemini --version`) and passes it as this build arg
# -- it isn't hardcoded, so this Dockerfile stays correct across machines with different CLI
# versions and across your own gemini-cli upgrades (just re-run install.sh).
ARG GEMINI_CLI_VERSION=0.57.0
FROM us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:${GEMINI_CLI_VERSION} AS base

USER root

# No Docker CLI/daemon access in this image, deliberately -- the sandbox does not get the host's
# docker.sock bind-mounted in (see bin/gemini-sandbox), so a Docker client here would have nothing
# to talk to anyway. `make` stays for build/test targets that don't need Docker; curl +
# ca-certificates are needed below to install the second Node runtime via NodeSource.
RUN apt-get update && apt-get install -y --no-install-recommends \
        make \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The base image bundles its own Node (currently v20.20.2) at /usr/local/bin/node -- left
# untouched, deliberately: gemini's own launcher script resolves `node` via `#!/usr/bin/env node`
# (a PATH lookup, not a hardcoded path) and /usr/local/bin wins that lookup, so this is the Node
# version that runs the gemini CLI process itself inside the container. It's the one Google
# publishes and tests this image with -- don't repoint it at the runtime below, even though a
# quick `gemini --version` smoke test was observed to still pass on Node 24 (confirmed 2026-09;
# not proof the full CLI is fine on an untested major version).
#
# Some MCP servers (e.g. ai-intake-mcp) require Node >=24 and ship native addons built against a
# specific Node major, so a second runtime lives here at a different path; NodeSource installs to
# /usr/bin/node (currently tracks the 24.x line, so it stays current automatically), so both
# coexist. THE CONVENTION FOR ANY NEW MCP SERVER THAT NEEDS A MODERN NODE: register it in
# merge-settings.js with `command: "/usr/bin/node"` -- the absolute path, never bare `"node"`.
# Bare `"node"` in a mcpServers entry resolves to the OLD bundled v20 (same PATH-lookup mechanism
# as gemini's own launcher above), which is exactly the native-addon ABI mismatch that breaks a
# server needing >=24 with a bare "Connection closed" error and no more specific reason in the
# logs -- see debug.sh's ai-intake check, which detects and warns about exactly this mistake.
#
# Pulled into its own named stage (not just another RUN below) so the better-sqlite3 builder stage
# further down can reuse this exact runtime without duplicating the two RUN blocks above and below.
FROM base AS with-node24
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- better-sqlite3 builder -----------------------------------------------------------------
# Only reached via `docker build --target better-sqlite3-builder` (see Makefile's
# rebuild-better-sqlite3 target) -- never part of the normal install.sh build below, so it costs
# a normal image build nothing. Its whole job is to reproduce the ~2min from-source compile once,
# on demand, so the result can be checked into prebuilt/ and reused by every build after that
# instead of paying this cost every time. Node/apt setup identical to the runtime the final image
# actually ships (via with-node24 above), specifically so the compiled ABI matches.
FROM with-node24 AS better-sqlite3-builder
ARG BETTER_SQLITE3_VERSION=11.10.0
# `-g --prefix /tmp/build` (not a plain `--prefix` project-scoped install): npm 11 rejects
# --allow-scripts outright on project-scoped installs ("--allow-scripts is not allowed in
# project-scoped installs" -- confirmed directly), so this needs the same global-style install
# npm uses for the real image, just rooted at a throwaway prefix instead of the system one.
RUN PATH=/usr/bin:$PATH npm install -g --prefix /tmp/build --allow-scripts=better-sqlite3 \
        better-sqlite3@${BETTER_SQLITE3_VERSION} \
    && cp /tmp/build/lib/node_modules/better-sqlite3/build/Release/better_sqlite3.node /tmp/better_sqlite3.node

# --- final image -----------------------------------------------------------------------------
FROM with-node24 AS final

# keytar (an ai-intake-mcp dependency, see below) links libsecret at runtime via dlopen, not at
# link/build time -- its own install step succeeds either way (it ships a prebuilt binary, unlike
# better-sqlite3 below), so the gap only shows up the first time a tool actually calls it, as
# `libsecret-1.so.0: cannot open shared object file` with no more specific reason in the logs.
# Runtime lib only (no -dev): nothing here compiles against it.
RUN apt-get update && apt-get install -y --no-install-recommends libsecret-1-0 \
    && rm -rf /var/lib/apt/lists/*

# ai-intake-mcp / ai-intake-documentation-mcp: baked in at pinned published versions (bump these
# ARGs and re-run install.sh to update -- same convention as chrome-devtools-mcp below).
# `env` (not calling npm directly) is required, not stylistic: npm's own CLI script also resolves
# `node` via `#!/usr/bin/env node`, so without forcing PATH here it silently installs against the
# bundled v20 above instead of this v24 runtime (confirmed: `npm warn EBADENGINE ... current: {
# node: 'v20.20.2' }` without this). `--allow-scripts` is required too, separately: npm 11 skips
# native-addon install scripts unless the package is explicitly allow-listed -- without it the
# install "succeeds" in seconds but silently leaves the compiled .node binaries missing, which
# only breaks at runtime once a tool that needs them is actually called, not at startup.
#
# better-sqlite3 is deliberately NOT in that allow-list, unlike keytar: its checked-in prebuilt
# (see prebuilt/better-sqlite3/, and the COPY + fallback below) makes its own install script
# redundant, and leaving it un-allow-listed means that script (`prebuild-install || node-gyp
# rebuild --release`) never runs at all here -- no wasted ~2min compile attempt, since no prebuilt
# binary exists yet for Node 24 on any platform (checked its GitHub releases directly) and it
# would otherwise always fall through to compiling from source.
#
# @davindermahal/confluence-client: the shared Confluence transport both packages above now
# depend on (as of ai-intake-mcp 0.3.0 / documentation-mcp 0.4.0, backing documentation-mcp's new
# fetch_confluence_pages tool) -- npm would resolve it transitively either way, but it's pinned
# explicitly here too, same as its sibling @davindermahal/context-schema was left implicit only
# because that one predates this image ever having pinned versions at all. Pure JS, no native
# addons, so it needs nothing from --allow-scripts.
ARG AI_INTAKE_MCP_VERSION=0.3.0
ARG AI_INTAKE_DOCUMENTATION_MCP_VERSION=0.4.0
ARG AI_INTAKE_CONFLUENCE_CLIENT_VERSION=0.1.0
ARG BETTER_SQLITE3_VERSION=11.10.0
RUN PATH=/usr/bin:$PATH npm install -g --allow-scripts=keytar \
    @davindermahal/ai-intake-mcp@${AI_INTAKE_MCP_VERSION} \
    @davindermahal/documentation-mcp@${AI_INTAKE_DOCUMENTATION_MCP_VERSION} \
    @davindermahal/confluence-client@${AI_INTAKE_CONFLUENCE_CLIENT_VERSION}

# Drop the checked-in prebuilt straight into the path npm would otherwise have compiled it to
# (verified directly: /usr/local/share/npm-global/.../ai-intake-mcp/node_modules/better-sqlite3/
# build/Release/). Requires install.sh to build with a real context (a tar of this file +
# prebuilt/ piped to stdin), not the old plain `- < sandbox.Dockerfile` -- see install.sh's
# comment on that for why a directory context (`-f sandbox.Dockerfile .`) is still avoided.
COPY prebuilt/better-sqlite3/${BETTER_SQLITE3_VERSION}/node137-linux-x64/better_sqlite3.node \
    /usr/local/share/npm-global/lib/node_modules/@davindermahal/ai-intake-mcp/node_modules/better-sqlite3/build/Release/better_sqlite3.node

# Smoke-test the copied binary immediately at build time, not the first time some tool happens to
# call it at runtime. If BETTER_SQLITE3_VERSION was bumped without regenerating prebuilt/ (or the
# Node major changes, changing the ABI), this falls back to compiling from source right here --
# same command that worked before this file started shipping a prebuilt -- so the build still
# succeeds, just slow again, and leaves a marker install.sh checks and reports on afterward
# (rather than a warning that scrolls out of view in `docker build` output).
RUN set -e; \
    BSQ3_DIR=/usr/local/share/npm-global/lib/node_modules/@davindermahal/ai-intake-mcp/node_modules/better-sqlite3; \
    if PATH=/usr/bin:$PATH node -e "new (require('$BSQ3_DIR'))(':memory:').close()"; then \
        echo "==> better-sqlite3: checked-in prebuilt binary loaded OK, skipped the ~2min compile"; \
    else \
        echo "=================================================================="; \
        echo "WARNING: checked-in better-sqlite3 prebuilt didn't load (stale, or ABI mismatch)."; \
        echo "Falling back to compiling from source now. Run 'make rebuild-better-sqlite3' in the"; \
        echo "toolkit repo afterward to refresh the checked-in binary for next time."; \
        echo "=================================================================="; \
        (cd "$BSQ3_DIR" && PATH=/usr/bin:$PATH npm run build-release); \
        mkdir -p /etc && touch /etc/gemini-sandbox-better-sqlite3-fallback; \
    fi

# chrome-devtools-mcp: Chromium's own internal sandbox needs unprivileged user namespaces this
# container doesn't grant (verified: fails with "No usable sandbox!" even as a non-root user with
# the default docker run flags used here) -- that's ordinary Docker+Chrome behavior, not specific
# to this image, worked around via --chrome-arg=--no-sandbox on Chrome itself in this MCP
# server's registration (see ~/.gemini/settings.json after running install.sh), not by adding
# container privileges. chrome-devtools-mcp declares engines.node "^20.19.0 || ^22.12.0 || >=23",
# which the base image's bundled Node already satisfies -- installed globally at build time (not
# `npx ...@latest` per session) for a pinned version and no per-session network fetch.
RUN apt-get update && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g chrome-devtools-mcp@1.8.0 \
    && chown -R node:node /usr/local/share/npm-global 2>/dev/null || true

USER node
