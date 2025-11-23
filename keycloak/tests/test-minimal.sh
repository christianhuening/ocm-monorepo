#!/usr/bin/env bash
#
# Test script for minimal Keycloak deployment on kind cluster
#
# This script:
# 1. Creates a kind cluster
# 2. Installs the Keycloak operator
# 3. Deploys minimal Keycloak configuration
# 4. Waits for deployment to be ready
# 5. Verifies Keycloak is accessible
# 6. Cleans up resources

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="keycloak-test"
NAMESPACE="keycloak"
TIMEOUT=600  # 10 minutes

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    log_info "Cleaning up resources..."
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
}

# Trap errors and cleanup
trap cleanup EXIT

# Main test flow
main() {
    log_info "Starting Keycloak minimal configuration test..."

    # Check prerequisites
    log_info "Checking prerequisites..."
    command -v kind >/dev/null 2>&1 || { log_error "kind is not installed. Please install kind first."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is not installed. Please install kubectl first."; exit 1; }
    command -v curl >/dev/null 2>&1 || { log_error "curl is not installed. Please install curl first."; exit 1; }

    # Create kind cluster
    log_info "Creating kind cluster: $CLUSTER_NAME"
    kind create cluster --name "$CLUSTER_NAME" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  - containerPort: 8443
    hostPort: 8443
    protocol: TCP
EOF

    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    # Install Keycloak operator
    log_info "Installing Keycloak operator CRDs..."
    kubectl apply -f ../operator/keycloaks-crd.yml
    kubectl apply -f ../operator/keycloakrealmimports-crd.yml

    log_info "Installing Keycloak operator..."
    kubectl apply -f ../operator/operator.yml

    # Wait for operator to be ready
    log_info "Waiting for operator to be ready..."
    kubectl wait --for=condition=Available deployment/keycloak-operator --timeout=120s || {
        log_error "Operator failed to become ready"
        kubectl describe deployment keycloak-operator
        kubectl logs -l app.kubernetes.io/name=keycloak-operator --tail=50
        exit 1
    }

    # Generate self-signed certificate for testing
    log_info "Generating self-signed TLS certificate..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /tmp/tls.key -out /tmp/tls.crt \
        -subj "/CN=keycloak.local" 2>/dev/null

    # Create namespace
    kubectl create namespace "$NAMESPACE" || true

    # Create TLS secret
    kubectl create secret tls keycloak-tls-secret \
        -n "$NAMESPACE" \
        --cert=/tmp/tls.crt \
        --key=/tmp/tls.key \
        --dry-run=client -o yaml | kubectl apply -f -

    # Deploy minimal Keycloak
    log_info "Deploying minimal Keycloak configuration..."

    # Modify the minimal config to use the TLS secret we just created
    kubectl apply -f ../configs/minimal/keycloak.yml

    # Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=Available deployment/postgres-db -n "$NAMESPACE" --timeout=180s || {
        log_error "PostgreSQL failed to become ready"
        kubectl describe deployment postgres-db -n "$NAMESPACE"
        kubectl logs -l app=postgres -n "$NAMESPACE" --tail=50
        exit 1
    }

    # Wait for Keycloak to be ready
    log_info "Waiting for Keycloak to be ready (this may take several minutes)..."

    # Wait for the Keycloak CR to have status
    timeout=0
    while [ $timeout -lt $TIMEOUT ]; do
        status=$(kubectl get keycloak -n "$NAMESPACE" keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$status" = "True" ]; then
            log_info "Keycloak is ready!"
            break
        fi
        if [ "$status" = "False" ]; then
            reason=$(kubectl get keycloak -n "$NAMESPACE" keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "Unknown")
            log_warn "Keycloak not ready yet: $reason"
        fi
        sleep 10
        timeout=$((timeout + 10))
    done

    if [ $timeout -ge $TIMEOUT ]; then
        log_error "Timeout waiting for Keycloak to be ready"
        kubectl get keycloak -n "$NAMESPACE" -o yaml
        kubectl get pods -n "$NAMESPACE"
        kubectl logs -l app=keycloak-app -n "$NAMESPACE" --tail=100
        exit 1
    fi

    # Get admin credentials
    log_info "Retrieving admin credentials..."
    admin_username=$(kubectl get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
    admin_password=$(kubectl get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

    log_info "Admin credentials:"
    log_info "  Username: $admin_username"
    log_info "  Password: $admin_password"

    # Port forward to Keycloak
    log_info "Setting up port forward to Keycloak..."
    kubectl port-forward -n "$NAMESPACE" svc/keycloak-service 8443:8443 &
    PF_PID=$!
    sleep 5

    # Test Keycloak endpoint
    log_info "Testing Keycloak endpoint..."
    if curl -k -s -f https://localhost:8443 >/dev/null; then
        log_info "✓ Keycloak is accessible!"
    else
        log_error "✗ Keycloak is not accessible"
        kill $PF_PID 2>/dev/null || true
        exit 1
    fi

    # Test health endpoint
    log_info "Testing Keycloak health endpoint..."
    health_status=$(curl -k -s https://localhost:8443/health/ready | grep -o '"status":"UP"' || echo "DOWN")
    if [ "$health_status" = '"status":"UP"' ]; then
        log_info "✓ Keycloak health check passed!"
    else
        log_warn "Keycloak health check returned: $health_status"
    fi

    # Kill port forward
    kill $PF_PID 2>/dev/null || true

    # Print summary
    log_info "========================================="
    log_info "Test Summary"
    log_info "========================================="
    log_info "✓ Kind cluster created successfully"
    log_info "✓ Keycloak operator installed"
    log_info "✓ Keycloak deployed and running"
    log_info "✓ Keycloak is accessible"
    log_info "========================================="
    log_info ""
    log_info "To access Keycloak manually:"
    log_info "  kubectl port-forward -n $NAMESPACE svc/keycloak-service 8443:8443"
    log_info "  Then visit: https://localhost:8443"
    log_info ""
    log_info "Admin credentials:"
    log_info "  Username: $admin_username"
    log_info "  Password: $admin_password"
    log_info ""
    log_info "To keep the cluster running, press Ctrl+C now."
    log_info "Otherwise, the cluster will be deleted in 10 seconds..."

    sleep 10
}

main "$@"
