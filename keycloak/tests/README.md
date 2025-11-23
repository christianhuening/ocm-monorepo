# Keycloak Tests

This directory contains test scripts for validating Keycloak deployments.

## Prerequisites

Before running tests, ensure you have the following installed:

- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) (Kubernetes in Docker)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [curl](https://curl.se/)
- [openssl](https://www.openssl.org/)

## Available Tests

### test-minimal.sh

Tests the minimal Keycloak configuration on a local kind cluster.

**What it does:**
1. Creates a fresh kind cluster
2. Installs Keycloak operator
3. Generates self-signed TLS certificate
4. Deploys minimal Keycloak configuration
5. Waits for all components to be ready
6. Verifies Keycloak is accessible
7. Runs health checks
8. Cleans up resources (unless interrupted)

**Usage:**

```bash
./test-minimal.sh
```

**Expected Output:**
```
[INFO] Starting Keycloak minimal configuration test...
[INFO] Checking prerequisites...
[INFO] Creating kind cluster: keycloak-test
[INFO] Waiting for cluster to be ready...
[INFO] Installing Keycloak operator CRDs...
[INFO] Installing Keycloak operator...
[INFO] Waiting for operator to be ready...
[INFO] Generating self-signed TLS certificate...
[INFO] Deploying minimal Keycloak configuration...
[INFO] Waiting for PostgreSQL to be ready...
[INFO] Waiting for Keycloak to be ready (this may take several minutes)...
[INFO] Keycloak is ready!
[INFO] Retrieving admin credentials...
[INFO] Admin credentials:
[INFO]   Username: admin
[INFO]   Password: <generated-password>
[INFO] Testing Keycloak endpoint...
[INFO] ✓ Keycloak is accessible!
[INFO] ✓ Keycloak health check passed!
[INFO] =========================================
[INFO] Test Summary
[INFO] =========================================
[INFO] ✓ Kind cluster created successfully
[INFO] ✓ Keycloak operator installed
[INFO] ✓ Keycloak deployed and running
[INFO] ✓ Keycloak is accessible
```

**Duration:** ~5-10 minutes (depending on your internet connection and machine)

**Keep Cluster Running:**

If you want to keep the cluster running for manual testing, press `Ctrl+C` when prompted. The script gives you 10 seconds before auto-cleanup.

To manually access Keycloak after keeping the cluster:
```bash
kubectl port-forward -n keycloak svc/keycloak-service 8443:8443
```

Then visit: https://localhost:8443

**Manual Cleanup:**

If you interrupted the script and want to clean up later:
```bash
kind delete cluster --name keycloak-test
```

## Troubleshooting

### Test fails with "Timeout waiting for Keycloak to be ready"

This usually happens due to resource constraints. Try:

1. Increase the timeout in the script
2. Check if your machine has enough resources (4GB RAM minimum recommended)
3. View logs: `kubectl logs -l app=keycloak-app -n keycloak`

### Port forward fails with "bind: address already in use"

Another process is using port 8443. Either:
- Kill the process using that port
- Change the port mapping in the script

### PostgreSQL fails to start

Check the pod logs:
```bash
kubectl logs -l app=postgres -n keycloak
```

Common issues:
- Insufficient memory
- Docker resource limits

### Operator installation fails

Check operator logs:
```bash
kubectl logs -l app.kubernetes.io/name=keycloak-operator
```

## Adding New Tests

When creating new test scripts:

1. Follow the same structure as `test-minimal.sh`
2. Include cleanup on exit using `trap cleanup EXIT`
3. Add colored output for better readability
4. Include timeout handling
5. Provide clear error messages
6. Test both success and failure paths
7. Document the test in this README

## CI/CD Integration

These tests can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Test Keycloak Minimal
  run: |
    cd keycloak/tests
    ./test-minimal.sh
```

For CI environments, consider:
- Disabling interactive prompts
- Reducing timeouts
- Capturing logs as artifacts on failure
- Running tests in parallel (if multiple test scripts exist)

## Future Tests

Planned test scripts:

- `test-production.sh`: Test production configuration (requires more resources)
- `test-upgrade.sh`: Test upgrade path from previous version
- `test-ha.sh`: Test high availability failover
- `test-realm-import.sh`: Test realm import functionality
