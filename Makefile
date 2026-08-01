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

.PHONY: test-godot
test-godot: ## Run Godot unit tests with GUT (headless)
	@echo "Running tests..."
	@godot --headless -s --path . addons/gut/gut_cmdln.gd -gexit 2>&1 | grep -E "(Failed|Error|PASSED|passed)" || true

##@ Addons

.PHONY: addons-install
addons-install: ## Install Godot addons from addons.jsonc
	godotenv addons install

##@ Documentation

.PHONY: check-docs
check-docs: ## Check consistency of README and LICENSE between root and addon directory
	@echo "Checking documentation consistency..."
	@diff -u README.md addons/gd-time-machine/README.md || (echo "ERROR: README.md differs between root and addon directory (see diff above). Run 'make sync-docs' to sync." && exit 1)
	@diff -u LICENSE.txt addons/gd-time-machine/LICENSE.txt || (echo "ERROR: LICENSE.txt differs between root and addon directory (see diff above). Run 'make sync-docs' to sync." && exit 1)
	@echo "Documentation is consistent"

.PHONY: sync-docs
sync-docs: ## Copy README and LICENSE from root to addon directory
	@echo "Syncing documentation to addon directory..."
	@cp README.md addons/gd-time-machine/README.md
	@cp LICENSE.txt addons/gd-time-machine/LICENSE.txt
	@echo "Documentation synced successfully"

##@ Help

.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "}; /^##@ / {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)}; /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
