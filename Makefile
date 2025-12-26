.PHONY: test-unit test-component test-integration test-load test-all test-coverage help

# Default target
help:
	@echo "Unifra APISIX Test Commands"
	@echo "==========================="
	@echo ""
	@echo "  make test-unit          Run unit tests (fast, no dependencies)"
	@echo "  make test-component     Run component tests (requires Redis)"
	@echo "  make test-integration   Run integration tests (full Docker stack)"
	@echo "  make test-load          Run load tests (requires k6)"
	@echo "  make test-all           Run all tests in sequence"
	@echo "  make test-coverage      Run tests with coverage report"
	@echo ""
	@echo "  make dev-setup          Set up local development environment"
	@echo "  make docker-up          Start Docker test environment"
	@echo "  make docker-down        Stop Docker test environment"
	@echo ""

# Check if busted is available
check-busted:
	@command -v busted >/dev/null 2>&1 || { \
		echo "Error: busted not found. Install with: luarocks install busted"; \
		exit 1; \
	}

# Unit tests - fast, no dependencies
test-unit: check-busted
	@echo "Running unit tests..."
	@cd tests && busted unit/ --verbose --pattern=test

# Component tests - requires Redis
test-component: check-busted
	@echo "Starting Redis for component tests..."
	@docker run -d --name test-redis -p 6379:6379 redis:7-alpine >/dev/null 2>&1 || true
	@sleep 2
	@echo "Running component tests..."
	@REDIS_HOST=localhost REDIS_PORT=6379 busted tests/component/ --verbose --pattern=test || \
		(docker stop test-redis >/dev/null 2>&1; docker rm test-redis >/dev/null 2>&1; exit 1)
	@docker stop test-redis >/dev/null 2>&1
	@docker rm test-redis >/dev/null 2>&1
	@echo "Component tests completed."

# Integration tests - full Docker stack
test-integration:
	@echo "Starting full test environment..."
	@cd test-env && docker-compose up -d
	@echo "Waiting for services..."
	@sleep 10
	@./test-env/test-all.sh || (cd test-env && docker-compose down; exit 1)
	@cd test-env && docker-compose down
	@echo "Integration tests completed."

# Load tests - requires k6
test-load:
	@command -v k6 >/dev/null 2>&1 || { \
		echo "Error: k6 not found. Install from https://k6.io/docs/getting-started/installation/"; \
		exit 1; \
	}
	@echo "Starting test environment for load tests..."
	@cd test-env && docker-compose up -d
	@sleep 15
	@echo "Running load tests..."
	@k6 run tests/load/billing_accuracy_load.js || true
	@cd test-env && docker-compose down

# Run all tests
test-all: test-unit test-component test-integration
	@echo ""
	@echo "================================"
	@echo "All tests completed successfully!"
	@echo "================================"

# Coverage report
test-coverage: check-busted
	@echo "Running tests with coverage..."
	@cd tests && busted unit/ --coverage --verbose
	@echo "Coverage report generated."

# Development setup
dev-setup:
	@echo "Setting up development environment..."
	@./scripts/dev-setup.sh

# Docker environment management
docker-up:
	@cd test-env && docker-compose up -d
	@echo "Test environment started."

docker-down:
	@cd test-env && docker-compose down -v
	@echo "Test environment stopped."

# Minimal Docker for component tests
docker-redis:
	@docker run -d --name test-redis -p 6379:6379 redis:7-alpine
	@echo "Redis started on port 6379"

docker-redis-stop:
	@docker stop test-redis && docker rm test-redis
	@echo "Redis stopped"
