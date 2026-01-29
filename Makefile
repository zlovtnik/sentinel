# Process Sentinel - Makefile
# Oracle-Zig Microservice for Real-Time Process Monitoring

.PHONY: all build run test check clean deps fmt lint \
        docker-build docker-run docker-push \
        sql-deploy sql-validate \
        k8s-deploy k8s-delete k8s-logs \
        help dev release

# Configuration
PROJECT_NAME := process-sentinel
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_TIME := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Paths
ZIG := zig
BUILD_DIR := zig-out
BIN := $(BUILD_DIR)/bin/$(PROJECT_NAME)
DEPS_DIR := deps
ODPIC_DIR := $(DEPS_DIR)/odpi

# Oracle paths (can be overridden)
ORACLE_HOME ?= /opt/oracle/instantclient_21_12
ODPIC_PATH ?= $(ODPIC_DIR)

# Docker configuration
DOCKER_REGISTRY ?= ghcr.io
DOCKER_IMAGE := $(DOCKER_REGISTRY)/zlovtnik/$(PROJECT_NAME)
DOCKER_TAG ?= $(VERSION)

# Kubernetes configuration
K8S_NAMESPACE ?= sentinel
K8S_CONTEXT ?= $(shell kubectl config current-context 2>/dev/null)

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

#==============================================================================
# Default target
#==============================================================================
all: deps build

#==============================================================================
# Development targets
#==============================================================================

## deps: Install project dependencies (ODPI-C)
deps:
	@echo "$(GREEN)Installing dependencies...$(NC)"
	@if [ ! -d "$(ODPIC_DIR)" ]; then \
		echo "Cloning ODPI-C..."; \
		git clone --depth 1 https://github.com/oracle/odpi.git $(ODPIC_DIR); \
	else \
		echo "ODPI-C already present at $(ODPIC_DIR)"; \
	fi
	@echo "$(GREEN)Dependencies installed$(NC)"

## build: Build the project in debug mode
build: deps
	@echo "$(GREEN)Building $(PROJECT_NAME) (debug)...$(NC)"
	ORACLE_HOME=$(ORACLE_HOME) ODPIC_PATH=$(ODPIC_PATH) $(ZIG) build
	@echo "$(GREEN)Build complete: $(BIN)$(NC)"

## release: Build the project in release mode
release: deps
	@echo "$(GREEN)Building $(PROJECT_NAME) (release)...$(NC)"
	ORACLE_HOME=$(ORACLE_HOME) ODPIC_PATH=$(ODPIC_PATH) $(ZIG) build -Doptimize=ReleaseFast
	@echo "$(GREEN)Release build complete$(NC)"

## run: Build and run the application
run: build
	@echo "$(GREEN)Running $(PROJECT_NAME)...$(NC)"
	ORACLE_HOME=$(ORACLE_HOME) ODPIC_PATH=$(ODPIC_PATH) $(ZIG) build run

## dev: Run in development mode with auto-reload (requires entr)
dev:
	@echo "$(YELLOW)Watching for changes...$(NC)"
	@find src -name '*.zig' | entr -r make run

## test: Run all tests
test: deps
	@echo "$(GREEN)Running tests...$(NC)"
	ORACLE_HOME=$(ORACLE_HOME) ODPIC_PATH=$(ODPIC_PATH) $(ZIG) build test

## check: Fast syntax check (no linking)
check:
	@echo "$(GREEN)Running syntax check...$(NC)"
	$(ZIG) build check

## fmt: Format all Zig source files
fmt:
	@echo "$(GREEN)Formatting source files...$(NC)"
	$(ZIG) fmt src/

## fmt-check: Check formatting without modifying files
fmt-check:
	@echo "$(GREEN)Checking formatting...$(NC)"
	$(ZIG) fmt --check src/

## lint: Run static analysis (fmt-check + build check)
lint: fmt-check check
	@echo "$(GREEN)Lint complete$(NC)"

## clean: Remove build artifacts
clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	rm -rf $(BUILD_DIR)
	rm -rf .zig-cache
	@echo "$(GREEN)Clean complete$(NC)"

## clean-all: Remove build artifacts and dependencies
clean-all: clean
	@echo "$(YELLOW)Removing dependencies...$(NC)"
	rm -rf $(DEPS_DIR)
	@echo "$(GREEN)Full clean complete$(NC)"

#==============================================================================
# Docker targets
#==============================================================================

## docker-build: Build Docker image
docker-build:
	@echo "$(GREEN)Building Docker image $(DOCKER_IMAGE):$(DOCKER_TAG)...$(NC)"
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(DOCKER_IMAGE):$(DOCKER_TAG) \
		-t $(DOCKER_IMAGE):latest \
		.
	@echo "$(GREEN)Docker build complete$(NC)"

## docker-run: Run Docker container locally
docker-run:
	@echo "$(GREEN)Running Docker container...$(NC)"
	@if [ -f .env ]; then \
		docker run --rm -it \
			--name $(PROJECT_NAME) \
			-p 8090:8090 \
			-p 9090:9090 \
			-v $(HOME)/.oracle/wallet:/etc/oracle/wallet:ro \
			--env-file .env \
			$(DOCKER_IMAGE):$(DOCKER_TAG); \
	else \
		echo "$(YELLOW)Warning: .env file not found, running without env-file$(NC)"; \
		docker run --rm -it \
			--name $(PROJECT_NAME) \
			-p 8090:8090 \
			-p 9090:9090 \
			-v $(HOME)/.oracle/wallet:/etc/oracle/wallet:ro \
			$(DOCKER_IMAGE):$(DOCKER_TAG); \
	fi

## docker-push: Push Docker image to registry
docker-push: docker-build
	@echo "$(GREEN)Pushing Docker image...$(NC)"
	docker push $(DOCKER_IMAGE):$(DOCKER_TAG)
	docker push $(DOCKER_IMAGE):latest
	@echo "$(GREEN)Docker push complete$(NC)"

## docker-shell: Open shell in Docker container
docker-shell:
	docker run --rm -it \
		--entrypoint /bin/sh \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

#==============================================================================
# SQL targets
#==============================================================================

## sql-validate: Validate SQL syntax (requires sqlcl or sqlplus)
sql-validate:
	@echo "$(GREEN)Validating SQL files...$(NC)"
	@for f in sql/*.sql; do \
		echo "Checking $$f..."; \
	done
	@echo "$(GREEN)SQL validation complete$(NC)"

## sql-deploy: Deploy SQL schema to database (uses Oracle Wallet)
## Usage: make sql-deploy TNS_ALIAS=SENTINEL_DB
sql-deploy:
	@echo "$(YELLOW)Deploying SQL schema...$(NC)"
	@if [ -z "$(TNS_ALIAS)" ]; then \
		echo "$(RED)Error: TNS_ALIAS not set$(NC)"; \
		echo "Usage: make sql-deploy TNS_ALIAS=your_tns_alias"; \
		echo "Note: Uses Oracle Wallet for authentication (no credentials in command line)"; \
		exit 1; \
	fi
	@for f in sql/*.sql; do \
		echo "Executing $$f..."; \
		sqlplus -s /@$(TNS_ALIAS) @$$f; \
	done
	@echo "$(GREEN)SQL deployment complete$(NC)"

## sql-show: Display all SQL files in order
sql-show:
	@echo "$(GREEN)SQL files to be deployed:$(NC)"
	@ls -1 sql/*.sql

#==============================================================================
# Kubernetes targets
#==============================================================================

## k8s-deploy: Deploy to Kubernetes
k8s-deploy:
	@echo "$(GREEN)Deploying to Kubernetes ($(K8S_CONTEXT))...$(NC)"
	kubectl --context $(K8S_CONTEXT) apply -f k8s/namespace.yaml
	kubectl --context $(K8S_CONTEXT) apply -f k8s/configmap.yaml
	kubectl --context $(K8S_CONTEXT) apply -f k8s/rbac.yaml
	kubectl --context $(K8S_CONTEXT) apply -f k8s/service.yaml
	kubectl --context $(K8S_CONTEXT) apply -f k8s/deployment.yaml
	@echo "$(GREEN)Deployment complete$(NC)"

## k8s-delete: Remove from Kubernetes
k8s-delete:
	@echo "$(YELLOW)Removing from Kubernetes...$(NC)"
	kubectl --context $(K8S_CONTEXT) delete -f k8s/ --ignore-not-found
	@echo "$(GREEN)Removal complete$(NC)"

## k8s-status: Show deployment status
k8s-status:
	@echo "$(GREEN)Deployment status:$(NC)"
	kubectl --context $(K8S_CONTEXT) -n $(K8S_NAMESPACE) get pods,svc,deploy

## k8s-logs: Tail logs from Kubernetes pods
k8s-logs:
	kubectl -n $(K8S_NAMESPACE) logs -f -l app=$(PROJECT_NAME) --all-containers

## k8s-restart: Restart the deployment
k8s-restart:
	@echo "$(YELLOW)Restarting deployment...$(NC)"
	kubectl -n $(K8S_NAMESPACE) rollout restart deployment/$(PROJECT_NAME)

## k8s-port-forward: Forward local ports to the pod
k8s-port-forward:
	@echo "$(GREEN)Forwarding ports (API: 8090, Metrics: 9090)...$(NC)"
	kubectl -n $(K8S_NAMESPACE) port-forward svc/$(PROJECT_NAME) 8090:8090 9090:9090

#==============================================================================
# Health check targets
#==============================================================================

## health: Check application health endpoint
health:
	@curl -s http://localhost:8090/health | jq . || echo "Service not running"

## ready: Check application readiness endpoint
ready:
	@curl -s http://localhost:8090/ready | jq . || echo "Service not running"

## metrics: Fetch Prometheus metrics
metrics:
	@curl -s http://localhost:9090/metrics || echo "Metrics endpoint not available"

#==============================================================================
# Documentation targets
#==============================================================================

## docs: Generate documentation
docs:
	@echo "$(GREEN)Generating documentation...$(NC)"
	$(ZIG) build-lib src/main.zig -femit-docs

## spec: Open the development specification
spec:
	@$(EDITOR) process-sentinel-devspec.md

#==============================================================================
# CI/CD targets
#==============================================================================

## ci: Run full CI pipeline (lint + test + build)
ci: lint test release
	@echo "$(GREEN)CI pipeline complete$(NC)"

## version: Show version information
version:
	@echo "Project: $(PROJECT_NAME)"
	@echo "Version: $(VERSION)"
	@echo "Build Time: $(BUILD_TIME)"
	@echo "Zig: $$($(ZIG) version)"

#==============================================================================
# Environment targets
#==============================================================================

## env-check: Verify environment setup
env-check:
	@echo "$(GREEN)Checking environment...$(NC)"
	@echo "ORACLE_HOME: $(ORACLE_HOME)"
	@echo "ODPIC_PATH: $(ODPIC_PATH)"
	@if [ -d "$(ORACLE_HOME)" ]; then \
		echo "$(GREEN)✓ Oracle Instant Client found$(NC)"; \
	else \
		echo "$(RED)✗ Oracle Instant Client not found at $(ORACLE_HOME)$(NC)"; \
	fi
	@if [ -d "$(ODPIC_PATH)" ]; then \
		echo "$(GREEN)✓ ODPI-C found$(NC)"; \
	else \
		echo "$(YELLOW)✗ ODPI-C not found (run 'make deps')$(NC)"; \
	fi
	@if command -v $(ZIG) >/dev/null 2>&1; then \
		echo "$(GREEN)✓ Zig installed: $$($(ZIG) version)$(NC)"; \
	else \
		echo "$(RED)✗ Zig not installed$(NC)"; \
	fi

## env-template: Create .env template file
env-template:
	@echo "$(GREEN)Creating .env.template...$(NC)"
	@echo "# Process Sentinel Environment Configuration" > .env.template
	@echo "" >> .env.template
	@echo "# Oracle Database" >> .env.template
	@echo "ORACLE_TNS_NAME=your_tns_name" >> .env.template
	@echo "ORACLE_WALLET_LOCATION=/path/to/wallet" >> .env.template
	@echo "" >> .env.template
	@echo "# Application" >> .env.template
	@echo "SENTINEL_LISTEN_ADDRESS=0.0.0.0" >> .env.template
	@echo "SENTINEL_LISTEN_PORT=8090" >> .env.template
	@echo "SENTINEL_METRICS_PORT=9090" >> .env.template
	@echo "SENTINEL_WORKER_COUNT=4" >> .env.template
	@echo "" >> .env.template
	@echo "# Security" >> .env.template
	@echo "OAUTH2_JWK_SET_URI=https://keycloak.example.com/realms/clm/protocol/openid-connect/certs" >> .env.template
	@echo "OAUTH2_ISSUER_URI=https://keycloak.example.com/realms/clm" >> .env.template
	@echo "" >> .env.template
	@echo "# Telemetry" >> .env.template
	@echo "OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317" >> .env.template
	@echo "LOG_LEVEL=info" >> .env.template
	@echo "$(GREEN).env.template created$(NC)"

#==============================================================================
# Help target
#==============================================================================

## help: Show this help message
help:
	@echo "$(GREEN)Process Sentinel - Available targets:$(NC)"
	@echo ""
	@echo "$(YELLOW)Development:$(NC)"
	@grep -E '^## [a-zA-Z_-]+:' $(MAKEFILE_LIST) | grep -E 'build|run|dev|test|check|fmt|lint|clean' | \
		sed 's/## /  /' | sed 's/:/:	/'
	@echo ""
	@echo "$(YELLOW)Docker:$(NC)"
	@grep -E '^## docker-' $(MAKEFILE_LIST) | sed 's/## /  /' | sed 's/:/:	/'
	@echo ""
	@echo "$(YELLOW)SQL:$(NC)"
	@grep -E '^## sql-' $(MAKEFILE_LIST) | sed 's/## /  /' | sed 's/:/:	/'
	@echo ""
	@echo "$(YELLOW)Kubernetes:$(NC)"
	@grep -E '^## k8s-' $(MAKEFILE_LIST) | sed 's/## /  /' | sed 's/:/:	/'
	@echo ""
	@echo "$(YELLOW)Health & Monitoring:$(NC)"
	@grep -E '^## (health|ready|metrics):' $(MAKEFILE_LIST) | sed 's/## /  /' | sed 's/:/:	/'
	@echo ""
	@echo "$(YELLOW)CI/CD & Environment:$(NC)"
	@grep -E '^## (ci|version|env-|docs|spec):' $(MAKEFILE_LIST) | sed 's/## /  /' | sed 's/:/:	/'
