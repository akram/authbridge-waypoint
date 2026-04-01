# Auto-detect platform (OpenShift vs Kind)
IS_OPENSHIFT := $(shell kubectl api-resources 2>/dev/null | grep -q route.openshift.io && echo true || echo false)

# OpenShift configuration
OPENSHIFT_IMAGE_PROJECT ?= kagenti-images
OPENSHIFT_REGISTRY := image-registry.openshift-image-registry.svc:5000/$(OPENSHIFT_IMAGE_PROJECT)

# Kind configuration
KIND_REGISTRY ?= localhost:5000
CLUSTER_NAME ?= kagenti

# Platform-specific settings
ifeq ($(IS_OPENSHIFT),true)
    PLATFORM := openshift
    REGISTRY := $(OPENSHIFT_REGISTRY)
    KC_ROUTE := $(shell kubectl get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null)
    KC_URL := https://$(KC_ROUTE)
    KEYCLOAK_SVC := keycloak-service
    KEYCLOAK_NS := keycloak
else
    PLATFORM := kind
    REGISTRY := $(KIND_REGISTRY)
    KC_PORT := 18080
    KC_URL := http://localhost:$(KC_PORT)
    KEYCLOAK_SVC := keycloak-service
    KEYCLOAK_NS := keycloak
endif

TAG ?= latest
GOARCH ?= $(shell go env GOARCH)
SERVICES := demo-agent echo-tool time-tool token-exchange-service
REALM := kagenti

.PHONY: up test down platform

platform: ## Show detected platform and configuration
	@echo "Platform: $(PLATFORM)"
	@echo "Registry: $(REGISTRY)"
	@echo "KC_URL: $(KC_URL)"
	@echo "Services: $(SERVICES)"

up: ## Build, configure Keycloak, deploy everything
ifeq ($(IS_OPENSHIFT),true)
	@$(MAKE) up-openshift
else
	@$(MAKE) up-kind
endif

up-kind: ## Build and deploy on Kind
	@if ! kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_NAME)'; then \
		echo "ERROR: Kind cluster '$(CLUSTER_NAME)' not found."; exit 1; \
	fi
	@if ! kubectl get cm istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | grep -q kagenti-token-exchange; then \
		echo "ERROR: Istio mesh config missing 'kagenti-token-exchange' ext_authz provider."; exit 1; \
	fi
	@echo "=== Building for Kind ==="
	@for svc in $(SERVICES); do \
		CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o bin/$$svc ./cmd/$$svc/; \
	done
	@for svc in $(SERVICES); do \
		docker build -q -t $(REGISTRY)/$$svc:$(TAG) --build-arg SERVICE=$$svc -f Dockerfile .; \
		kind load docker-image $(REGISTRY)/$$svc:$(TAG) --name $(CLUSTER_NAME) 2>&1 | grep -v "^enabling"; \
	done
	@echo "=== Configuring Keycloak ==="
	@fuser -k $(KC_PORT)/tcp 2>/dev/null || true; \
		kubectl port-forward -n $(KEYCLOAK_NS) svc/$(KEYCLOAK_SVC) $(KC_PORT):8080 & PF_PID=$$!; \
		sleep 5; \
		KEYCLOAK_URL=$(KC_URL) bash deploy/03-keycloak-setup.sh; \
		kill $$PF_PID 2>/dev/null || true
	@echo "=== Deploying ==="
	kubectl apply -f deploy/04-namespaces.yaml
	kubectl apply -f deploy/06-waypoint.yaml
	kubectl apply -f deploy/05-token-exchange-svc.yaml
	kubectl apply -f deploy/07-istio-policies.yaml
	kubectl apply -f deploy/08-workloads.yaml
	@echo "=== Ready ==="

up-openshift: ## Build and deploy on OpenShift
	@if ! kubectl get cm istio -n istio-system -o jsonpath='{.data.mesh}' 2>/dev/null | grep -q kagenti-token-exchange; then \
		echo "ERROR: Istio mesh config missing 'kagenti-token-exchange' ext_authz provider."; exit 1; \
	fi
	@if [ -z "$(KC_ROUTE)" ]; then \
		echo "ERROR: Keycloak route not found in namespace $(KEYCLOAK_NS)"; exit 1; \
	fi
	@echo "=== Building on OpenShift (project: $(OPENSHIFT_IMAGE_PROJECT)) ==="
	@kubectl get namespace $(OPENSHIFT_IMAGE_PROJECT) >/dev/null 2>&1 || \
		(echo "ERROR: Namespace $(OPENSHIFT_IMAGE_PROJECT) not found."; exit 1)
	@for svc in $(SERVICES); do \
		if ! kubectl get buildconfig $$svc -n $(OPENSHIFT_IMAGE_PROJECT) >/dev/null 2>&1; then \
			echo "  ERROR: BuildConfig '$$svc' not found in $(OPENSHIFT_IMAGE_PROJECT)"; \
			echo "  Run: kubectl apply -f deploy/openshift/golang-s2i-buildconfigs.yaml"; \
			exit 1; \
		fi; \
	done
	@for svc in $(SERVICES); do \
		echo "  Starting build: $$svc"; \
		oc start-build $$svc -n $(OPENSHIFT_IMAGE_PROJECT) --follow --wait; \
	done
	@echo "=== Configuring Keycloak ($(KC_URL)) ==="
	@KEYCLOAK_URL=$(KC_URL) bash deploy/03-keycloak-setup.sh
	@echo "=== Updating token-exchange-service ISSUER_URL ==="
	@kubectl set env deployment/token-exchange-service -n kagenti-system \
		ISSUER_URL=$(KC_URL) 2>/dev/null || true
	@echo "=== Deploying ==="
	kubectl apply -f deploy/04-namespaces.yaml
	kubectl apply -f deploy/06-waypoint.yaml
	kubectl apply -f deploy/05-token-exchange-svc.yaml
	kubectl apply -f deploy/07-istio-policies.yaml
	kubectl apply -f deploy/08-workloads.yaml
	@echo "=== Updating workload images to use OpenShift registry ==="
	@for ns_dep in agent-ns/demo-agent tool-ns/echo-tool tool-ns/time-tool; do \
		ns=$${ns_dep%/*}; dep=$${ns_dep#*/}; \
		kubectl set image deployment/$$dep -n $$ns $$dep=$(REGISTRY)/$$dep:$(TAG) 2>/dev/null || true; \
	done
	@kubectl set image deployment/token-exchange-service -n kagenti-system \
		token-exchange-service=$(REGISTRY)/token-exchange-service:$(TAG) 2>/dev/null || true
	@echo "=== Waiting for rollout ==="
	@kubectl rollout status deployment/token-exchange-service -n kagenti-system --timeout=120s
	@kubectl rollout status deployment/demo-agent -n agent-ns --timeout=120s
	@kubectl rollout status deployment/echo-tool -n tool-ns --timeout=120s
	@kubectl rollout status deployment/time-tool -n tool-ns --timeout=120s
	@echo "=== Ready ==="

test: ## Run end-to-end tests
ifeq ($(IS_OPENSHIFT),true)
	@KC_URL=$(KC_URL) CURL_TEST_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest bash deploy/09-test.sh
else
	@bash deploy/09-test.sh
endif

WAYPOINT_CLIENTS := demo-agent echo-tool time-tool token-exchange-service

down: ## Remove all PoC resources and Keycloak clients (realm is shared, not deleted)
	@echo "=== Removing Kubernetes resources ==="
	-kubectl delete -f deploy/08-workloads.yaml 2>/dev/null
	-kubectl delete -f deploy/07-istio-policies.yaml 2>/dev/null
	-kubectl delete -f deploy/06-waypoint.yaml 2>/dev/null
	-kubectl delete -f deploy/05-token-exchange-svc.yaml 2>/dev/null
	-kubectl delete ns agent-ns tool-ns 2>/dev/null
	@echo "=== Removing Keycloak clients (realm '$(REALM)' is shared) ==="
	@fuser -k $(KC_PORT)/tcp 2>/dev/null || true; \
		kubectl port-forward -n keycloak svc/keycloak-service $(KC_PORT):8080 & PF_PID=$$!; \
		sleep 3; \
		ADMIN_TOKEN=$$(curl -sf -X POST "http://localhost:$(KC_PORT)/realms/master/protocol/openid-connect/token" \
			-d "grant_type=password&client_id=admin-cli&username=admin&password=admin" | jq -r '.access_token'); \
		if [ -n "$$ADMIN_TOKEN" ] && [ "$$ADMIN_TOKEN" != "null" ]; then \
			for CLIENT in $(WAYPOINT_CLIENTS); do \
				UUID=$$(curl -sf "http://localhost:$(KC_PORT)/admin/realms/$(REALM)/clients?clientId=$$CLIENT" \
					-H "Authorization: Bearer $$ADMIN_TOKEN" | jq -r '.[0].id'); \
				if [ -n "$$UUID" ] && [ "$$UUID" != "null" ]; then \
					curl -sf -o /dev/null -X DELETE "http://localhost:$(KC_PORT)/admin/realms/$(REALM)/clients/$$UUID" \
						-H "Authorization: Bearer $$ADMIN_TOKEN" \
						&& echo "   Deleted client '$$CLIENT'" \
						|| echo "   Client '$$CLIENT' already gone"; \
				fi; \
			done; \
		else \
			echo "   WARNING: Could not get admin token — clients not deleted"; \
		fi; \
		kill $$PF_PID 2>/dev/null || true
	-rm -rf bin/
