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
	@trap 'docker compose -f docker-compose.test.yml down -v' EXIT; \
		echo "Waiting for Streamline server..."; \
		ready=0; \
		for i in $$(seq 1 30); do \
			if curl -sf http://localhost:9094/health > /dev/null 2>&1; then \
				echo "Server ready"; \
				ready=1; \
				break; \
			fi; \
			sleep 2; \
		done; \
		test "$$ready" -eq 1; \
		STREAMLINE_HTTP_URL=http://localhost:9094 \
		STREAMLINE_WEBSOCKET_URL=ws://localhost:9092 \
		swift test --filter IntegrationTests
