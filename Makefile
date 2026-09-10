# Maintenance targets for this toolkit repo itself (not for any project using the sandbox).
# See sandbox.Dockerfile's comment on the better-sqlite3-builder stage for why this exists: a
# checked-in prebuilt binary avoids paying its ~2min from-source compile on every install.sh run,
# and these targets are how that binary gets regenerated when it needs to change.

TOOLKIT_DIR := $(shell pwd)
BETTER_SQLITE3_VERSION ?= 11.10.0
BSQ3_NODE_ABI_TAG := node137-linux-x64
BSQ3_PREBUILT_DIR := prebuilt/better-sqlite3/$(BETTER_SQLITE3_VERSION)/$(BSQ3_NODE_ABI_TAG)

.PHONY: check-better-sqlite3 rebuild-better-sqlite3

# Reports whether a newer better-sqlite3 is on npm than the one pinned in sandbox.Dockerfile /
# checked into prebuilt/. Informational only -- doesn't change anything.
check-better-sqlite3:
	@latest="$$(npm view better-sqlite3 version)"; \
	if [ "$$latest" = "$(BETTER_SQLITE3_VERSION)" ]; then \
		echo "better-sqlite3 prebuilt is current ($(BETTER_SQLITE3_VERSION))."; \
	else \
		echo "better-sqlite3 $$latest is available on npm (prebuilt here is pinned to $(BETTER_SQLITE3_VERSION))."; \
		echo "Run: make rebuild-better-sqlite3 BETTER_SQLITE3_VERSION=$$latest"; \
	fi

# Compiles better-sqlite3@$(BETTER_SQLITE3_VERSION) for this toolkit's target (linux/amd64, the
# Node 24 ABI sandbox.Dockerfile's with-node24 stage produces) and writes the resulting .node
# binary into prebuilt/. Same tar-context-via-stdin mechanism install.sh uses for the main build
# -- see its comment for why a plain directory context is avoided.
#
# After this: bump ARG BETTER_SQLITE3_VERSION in sandbox.Dockerfile to match, then commit both the
# new prebuilt/ file and the Dockerfile change together -- a mismatch between them just means the
# next install.sh build falls back to compiling from source (see sandbox.Dockerfile), not a broken
# image, but it defeats the point of this whole mechanism.
rebuild-better-sqlite3:
	@echo "==> Compiling better-sqlite3 $(BETTER_SQLITE3_VERSION) for linux/amd64, Node 24 ABI ($(BSQ3_NODE_ABI_TAG))"
	tar -czh -C "$(TOOLKIT_DIR)" sandbox.Dockerfile prebuilt | docker build \
		--target better-sqlite3-builder \
		--build-arg BETTER_SQLITE3_VERSION=$(BETTER_SQLITE3_VERSION) \
		-f sandbox.Dockerfile \
		-t gemini-sandbox-better-sqlite3-builder \
		-
	@mkdir -p $(BSQ3_PREBUILT_DIR)
	docker create --name gemini-sandbox-bsq3-extract gemini-sandbox-better-sqlite3-builder true >/dev/null
	docker cp gemini-sandbox-bsq3-extract:/tmp/better_sqlite3.node $(BSQ3_PREBUILT_DIR)/better_sqlite3.node
	docker rm gemini-sandbox-bsq3-extract >/dev/null
	@echo "==> Wrote $(BSQ3_PREBUILT_DIR)/better_sqlite3.node"
	@echo "    Now set ARG BETTER_SQLITE3_VERSION=$(BETTER_SQLITE3_VERSION) in sandbox.Dockerfile and commit both."

# --- MCP package version bumping -------------------------------------------------------------
# Same idea as check-better-sqlite3/rebuild-better-sqlite3 above, for the MCP-related npm packages
# pinned in sandbox.Dockerfile. better-sqlite3 stays out of this list -- its version is tied to a
# checked-in compiled binary, not just a version string, so it keeps its own pair above.

.PHONY: check-mcp-versions bump-mcp-versions upgrade-mcps

# ARG name in sandbox.Dockerfile : npm package name. Add a line here when a new MCP package gets
# baked into the image -- nothing else below needs to change.
define MCP_PACKAGES
AI_INTAKE_MCP_VERSION @davindermahal/ai-intake-mcp
AI_INTAKE_DOCUMENTATION_MCP_VERSION @davindermahal/documentation-mcp
AI_INTAKE_CONFLUENCE_CLIENT_VERSION @davindermahal/confluence-client
CHROME_DEVTOOLS_MCP_VERSION chrome-devtools-mcp
endef
export MCP_PACKAGES

# Reports which pinned MCP packages have a newer version on npm than sandbox.Dockerfile currently
# has. Informational only -- doesn't change anything.
check-mcp-versions:
	@echo "$$MCP_PACKAGES" | while read -r arg_name pkg_name; do \
		[ -z "$$arg_name" ] && continue; \
		current="$$(grep -m1 "^ARG $$arg_name=" sandbox.Dockerfile | cut -d= -f2)"; \
		latest="$$(npm view "$$pkg_name" version)"; \
		if [ "$$current" = "$$latest" ]; then \
			echo "$$pkg_name: $$current (current)"; \
		else \
			echo "$$pkg_name: $$current -> $$latest available"; \
		fi; \
	done

# Writes any newer versions found above straight into sandbox.Dockerfile's ARG lines. Idempotent --
# safe to run any time, a no-op if everything's already current. Deliberately stops there: it
# doesn't rebuild the image or touch CHANGELOG.md/git, same division of labor as
# rebuild-better-sqlite3 above -- see CLAUDE.md's "Releasing" section for what comes next
# (./install.sh to rebuild+register, ./debug.sh to smoke-test, then changelog/commit/tag/push).
bump-mcp-versions:
	@before="$$(md5sum sandbox.Dockerfile)"; \
	echo "$$MCP_PACKAGES" | while read -r arg_name pkg_name; do \
		[ -z "$$arg_name" ] && continue; \
		current="$$(grep -m1 "^ARG $$arg_name=" sandbox.Dockerfile | cut -d= -f2)"; \
		latest="$$(npm view "$$pkg_name" version)"; \
		if [ "$$current" != "$$latest" ]; then \
			sed -i "s/^ARG $$arg_name=.*/ARG $$arg_name=$$latest/" sandbox.Dockerfile; \
			echo "$$pkg_name: $$current -> $$latest"; \
		fi; \
	done; \
	after="$$(md5sum sandbox.Dockerfile)"; \
	if [ "$$before" = "$$after" ]; then \
		echo "All MCP packages already current -- nothing to bump."; \
	else \
		echo ""; \
		echo "Bumped sandbox.Dockerfile. Next: ./install.sh (rebuild+register), ./debug.sh (smoke"; \
		echo "test), then CHANGELOG.md + commit + tag + push per CLAUDE.md."; \
	fi

# The one-command version of the above: bump, rebuild+register, smoke-test. If nothing was
# outdated, ./install.sh's own Docker layer cache makes the "rebuild" a no-op in seconds -- no need
# to special-case that here. Stops short of CHANGELOG.md/commit/tag/push -- that still needs a
# human/agent to write the actual release notes; see CLAUDE.md's "Releasing" section for that part.
upgrade-mcps: bump-mcp-versions
	./install.sh
	./debug.sh
