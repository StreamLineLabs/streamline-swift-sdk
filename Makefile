.PHONY: integration-test build test lint fmt clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Compile the SDK
	swift build

test: ## Run all tests
	swift test

lint: ## Run linting checks
	@command -v swiftlint >/dev/null 2>&1 && swiftlint lint || echo "swiftlint not installed, skipping"

fmt: ## Format code
	@command -v swiftformat >/dev/null 2>&1 && swiftformat Sources Tests || echo "swiftformat not installed, skipping"

clean: ## Clean build artifacts
	swift package clean
	rm -rf .build

resolve: ## Resolve package dependencies
	swift package resolve

package: ## Build release
	swift build -c release

integration-test: ## Run integration tests (requires Docker)
	docker compose -f docker-compose.test.yml up -d
	@echo "Waiting for Streamline server..."
	@for i in $$(seq 1 30); do \
		if curl -sf http://localhost:9094/health/live > /dev/null 2>&1; then \
			echo "Server ready"; \
			break; \
		fi; \
		sleep 2; \
	done
	swift test --filter ConformanceTests || true
	docker compose -f docker-compose.test.yml down -v
