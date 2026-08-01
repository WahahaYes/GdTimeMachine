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

##@ Help

.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "}; /^##@ / {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)}; /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
