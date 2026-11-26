.PHONY: help build test lint format bundle demo clean

help: ## List targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

build: ## Debug build of the core and hook (SwiftPM)
	swift build

test: build ## Run the test suite serially (socket tests block threads; hook-binary tests need executables built first)
	swift test --no-parallel

lint: ## Check formatting/style (fails on any finding)
	swift format lint --strict -r Sources Tests App Shared Widget Package.swift

format: ## Auto-format in place
	swift format -i -r Sources Tests App Shared Widget Package.swift

bundle: ## Build dist/ClaudeNotch.app (Xcode 27.3+, needs a signing team; see scripts/bundle.sh)
	./scripts/bundle.sh

demo: bundle ## Launch the app with synthetic agents (no hooks needed)
	open -n dist/ClaudeNotch.app --args --demo

clean: ## Remove build output
	rm -rf .build build dist ClaudeNotch.xcodeproj
