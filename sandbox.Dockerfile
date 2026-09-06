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

# The base image bundles its own Node (older, used internally by the gemini-cli binary re-exec'd
# inside this sandbox) at /usr/local/bin/node -- left untouched. Some MCP servers (e.g.
# ai-intake-mcp) require Node >=24 and ship native addons built against a specific Node major, so
# a second runtime lives here at a different path; NodeSource installs to /usr/bin/node, so both
# coexist. Referenced by absolute path in mcpServers entries that need it.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

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
