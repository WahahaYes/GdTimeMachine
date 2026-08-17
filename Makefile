##@ Editor

.PHONY: launch-editor
launch-editor: ## Launch the Godot editor with this project (uses godotenv pinned version if available)
	@if command -v godotenv >/dev/null 2>&1; then \
		echo "Using godotenv pinned Godot version..."; \
		$$(godotenv godot env get) --editor --path .; \
	else \
		echo "Warning: godotenv not found, falling back to system godot"; \
		godot --editor --path .; \
	fi

##@ Testing

# test-godot runs the GUT suite and reports failures concisely.
# Exits 0 to preserve context; GUT-SUITE-OK/FAILED summary at end.
SHELL := /bin/bash

.PHONY: test-godot
test-godot: ## Run Godot unit tests with GUT (headless); concise output, exits 0
	@echo "Running tests..."
	@LOG=$$(mktemp /tmp/gut-XXXXXX.log); \
	godot --headless -s --path . addons/gut/gut_cmdln.gd -gexit 2>&1 > $$LOG; \
	STATUS=$$?; \
	OK=1; \
	for PAT in "SCRIPT ERROR" "Failed to load script" "Parse error"; do \
		if grep -qF "$$PAT" $$LOG; then \
			echo "GUT-SUITE-FAILED: output contains '$$PAT' (a test file failed to LOAD/parse)"; \
			OK=0; \
		fi; \
	done; \
	if [ $$STATUS -ne 0 ]; then \
		echo "GUT-SUITE-FAILED: gut_cmdln exited with $$STATUS"; \
		OK=0; \
	fi; \
	if [ $$OK -ne 1 ]; then \
		echo "GUT-SUITE-FAILED: see full log at $$LOG"; \
		grep -E "^(Passing Tests|Failing Tests|Asserts|Scripts|Warnings|Orphans)" $$LOG || cat $$LOG; \
	else \
		PASS=$$(grep -E "^Passing Tests" $$LOG | awk '{print $$NF}'); \
		FAIL=$$(grep -E "^Failing Tests" $$LOG | awk '{print $$NF}'); \
		[ -z "$$FAIL" ] && FAIL=0; \
		echo "GUT-SUITE-OK ($$PASS passing, $$FAIL failing)"; \
	fi; \
	exit 0

##@ Addons

.PHONY: addons-install
addons-install: ## Install Godot addons from addons.jsonc
	godotenv addons install

##@ Documentation

.PHONY: check-docs
check-docs: ## Check consistency of README and LICENSE between root and addon directory
	@echo "Checking documentation consistency..."
	@diff -u README.md addons/GdTimeMachine/README.md || (echo "ERROR: README.md differs between root and addon directory (see diff above). Run 'make sync-docs' to sync." && exit 1)
	@diff -u LICENSE.txt addons/GdTimeMachine/LICENSE.txt || (echo "ERROR: LICENSE.txt differs between root and addon directory (see diff above). Run 'make sync-docs' to sync." && exit 1)
	@echo "Documentation is consistent"

.PHONY: sync-docs
sync-docs: ## Copy README and LICENSE from root to addon directory
	@echo "Syncing documentation to addon directory..."
	@cp README.md addons/GdTimeMachine/README.md
	@cp LICENSE.txt addons/GdTimeMachine/LICENSE.txt
	@echo "Documentation synced successfully"

##@ Help

.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "}; /^##@ / {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)}; /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
