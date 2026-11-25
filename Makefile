.PHONY: help build test lint format bundle demo snapshots clean

help: ## List targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

build: ## Debug build
	swift build

test: build ## Run the test suite (hook-binary tests need the executables built first)
	swift test

lint: ## Check formatting/style (fails on any finding)
	swift format lint --strict -r Sources Tests Package.swift

format: ## Auto-format in place
	swift format -i -r Sources Tests Package.swift

bundle: ## Build dist/ClaudeNotch.app
	./scripts/bundle.sh

demo: bundle ## Launch the app with synthetic agents (no hooks needed)
	open -n dist/ClaudeNotch.app --args --demo

snapshots: build ## Re-render the README screenshots
	./scripts/snapshots.sh

clean: ## Remove build output
	rm -rf .build dist
