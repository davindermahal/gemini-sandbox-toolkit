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

# docker-ce-cli + docker-compose-plugin (from Docker's own apt repo -- Debian's bookworm repos
# don't carry a docker-compose-v2 package): lets `make`/`docker compose` run *inside* the sandbox,
# reaching the host's Docker daemon over the bind-mounted socket (Docker-outside-of-Docker) -- no
# Docker engine runs in this image, only the client + compose plugin.
RUN apt-get update && apt-get install -y --no-install-recommends \
        make \
        curl \
        ca-certificates \
        gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# The base image bundles its own Node (older, used internally by the gemini-cli binary re-exec'd
# inside this sandbox) at /usr/local/bin/node -- left untouched. Some MCP servers (e.g.
# ai-intake-mcp) require Node >=24 and ship native addons built against a specific Node major, so
# a second runtime lives here at a different path; NodeSource installs to /usr/bin/node, so both
# coexist. Referenced by absolute path in mcpServers entries that need it.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Align this image's `docker` group GID with the host's so the base image's non-root `node` user
# can use the bind-mounted docker.sock (group-owned, not world-writable). Override at build time
# if the host's GID differs -- check with `getent group docker`. install.sh passes this
# automatically.
ARG DOCKER_GID=984
RUN groupmod -g ${DOCKER_GID} docker 2>/dev/null || groupadd -g ${DOCKER_GID} docker
RUN usermod -aG docker node

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
