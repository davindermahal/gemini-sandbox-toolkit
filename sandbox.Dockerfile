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
FROM us-docker.pkg.dev/gemini-code-dev/gemini-cli/sandbox:${GEMINI_CLI_VERSION}

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
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ai-intake-mcp / ai-intake-documentation-mcp: baked in at pinned published versions (bump these
# two ARGs and re-run install.sh to update -- same convention as chrome-devtools-mcp below).
# `env` (not calling npm directly) is required, not stylistic: npm's own CLI script also resolves
# `node` via `#!/usr/bin/env node`, so without forcing PATH here it silently installs against the
# bundled v20 above instead of this v24 runtime (confirmed: `npm warn EBADENGINE ... current: {
# node: 'v20.20.2' }` without this). `--allow-scripts` is required too, separately: npm 11 skips
# native-addon install scripts (ai-intake-mcp depends on better-sqlite3 and keytar) unless the
# package is explicitly allow-listed -- without it the install "succeeds" in seconds but silently
# leaves the compiled .node binaries missing, which only breaks at runtime once a tool that needs
# them is actually called, not at startup. This step is the one place that cost is paid -- once,
# at image-build time -- specifically because better-sqlite3 has no prebuilt binary for Node 24 on
# any platform yet (checked its GitHub releases directly), so this always compiles from source
# here (~2 minutes); that's why `make` above matters too (node-gyp needs it, plus the gcc/python3
# the base image already bundles).
ARG AI_INTAKE_MCP_VERSION=0.2.0
ARG AI_INTAKE_DOCUMENTATION_MCP_VERSION=0.3.0
RUN PATH=/usr/bin:$PATH npm install -g --allow-scripts=better-sqlite3,keytar \
    @davindermahal/ai-intake-mcp@${AI_INTAKE_MCP_VERSION} \
    @davindermahal/documentation-mcp@${AI_INTAKE_DOCUMENTATION_MCP_VERSION}

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
