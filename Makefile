.PHONY: help build test lint format bundle demo snapshots release prerelease clean

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

snapshots: bundle ## Re-render docs/screens/*.png from the demo data (offscreen)
	dist/ClaudeNotch.app/Contents/MacOS/ClaudeNotch --snapshot docs/screens

release: ## Signed, notarized stable release of VERSION: GitHub Release + Homebrew cask (see docs/RELEASING.md)
	./scripts/release.sh

prerelease: ## Signed, notarized prerelease build of HEAD (tag build-N), no cask update
	./scripts/release.sh --prerelease

clean: ## Remove build output
	rm -rf .build build dist ClaudeNotch.xcodeproj
