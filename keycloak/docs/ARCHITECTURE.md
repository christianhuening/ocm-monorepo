# Keycloak Component Architecture

This document describes the architecture and design decisions for the Keycloak OCM component.

## Overview

The Keycloak component packages the official Keycloak Operator and Keycloak application server for deployment in Kubernetes environments. It follows the Open Component Model (OCM) specification for packaging and distribution.

## Component Structure

### Operator-Based Deployment

This component uses the **operator pattern** rather than direct Helm charts:

**Why the Operator Approach?**
- **Official Support**: The Keycloak project officially supports and maintains the operator
- **Dynamic Configuration**: Operators provide runtime configuration and management
- **Self-Healing**: Automatic recovery from failures and configuration drift
- **Lifecycle Management**: Automated updates, backups, and scaling
- **Cloud-Native**: Better integration with Kubernetes ecosystem

### Layered Architecture

```
┌─────────────────────────────────────────────────┐
│         Keycloak OCM Component                  │
├─────────────────────────────────────────────────┤
│  Operator Layer                                 │
│  - CRDs (Keycloak, KeycloakRealmImport)        │
│  - Operator Deployment (quay.io/../operator)    │
│  - RBAC (ClusterRoles, RoleBindings)           │
├─────────────────────────────────────────────────┤
│  Application Layer                              │
│  - Keycloak StatefulSet (managed by operator)  │
│  - Keycloak Image (quay.io/../keycloak)        │
│  - Service, Ingress                            │
├─────────────────────────────────────────────────┤
│  Data Layer                                     │
│  - PostgreSQL Database                         │
│  - Distributed Cache (Infinispan)              │
│  - Persistent Volumes                          │
└─────────────────────────────────────────────────┘
```

## Configuration Profiles

### Minimal Configuration

**Target**: Development, testing, CI/CD

**Characteristics**:
- Single Keycloak instance
- Ephemeral PostgreSQL (data loss on restart)
- Self-signed TLS certificate
- Minimal resource allocation (500m CPU, 512Mi RAM)
- Disabled advanced features

**Trade-offs**:
- ❌ No high availability
- ❌ Data loss on pod restart
- ❌ Not suitable for production
- ✅ Fast startup
- ✅ Low resource usage
- ✅ Simple setup

### Production Configuration

**Target**: Production deployments

**Characteristics**:
- 3 Keycloak replicas (HA)
- External PostgreSQL database
- Valid TLS certificates (cert-manager)
- Production resource limits (2-6 CPU, 1250-2250Mi RAM)
- Distributed caching with Infinispan
- Pod anti-affinity and topology spread
- Horizontal Pod Autoscaler (3-10 replicas)
- Pod Disruption Budget (min 2 available)
- Network policies
- Metrics and monitoring

**Trade-offs**:
- ✅ High availability
- ✅ Data persistence
- ✅ Auto-scaling
- ✅ Security hardening
- ❌ Higher resource usage
- ❌ More complex setup
- ❌ Requires external dependencies

## Dependencies

### Required Dependencies

1. **PostgreSQL Database**
   - **Minimal**: Included as ephemeral deployment
   - **Production**: External (CloudNativePG recommended)
   - **Why**: Keycloak requires a relational database for persistence

2. **TLS Certificates**
   - **Minimal**: Self-signed certificate included
   - **Production**: cert-manager for automated management
   - **Why**: Keycloak requires TLS for secure communication

### Optional Dependencies (Production)

3. **Ingress Controller**
   - NGINX Ingress Controller (recommended)
   - **Why**: External access to Keycloak services

4. **External Secrets Operator**
   - Secure secret management
   - **Why**: Production security best practice

5. **Prometheus Operator**
   - Metrics and monitoring
   - **Why**: Observability and alerting

6. **cert-manager**
   - Automated TLS certificate management
   - **Why**: Production-grade certificate lifecycle

## High Availability Design

### Stateless Application Tier

Keycloak instances are stateless and can be scaled horizontally:

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Keycloak   │    │  Keycloak   │    │  Keycloak   │
│  Pod 1      │◄──►│  Pod 2      │◄──►│  Pod 3      │
└─────────────┘    └─────────────┘    └─────────────┘
       │                  │                  │
       └──────────────────┴──────────────────┘
                          │
                    Distributed Cache
                      (Infinispan)
                          │
                   ┌──────────────┐
                   │  PostgreSQL  │
                   │  (External)  │
                   └──────────────┘
```

### Distributed Caching

- **JGroups** for cluster discovery (kubernetes stack)
- **Infinispan** for distributed caching
- Cache types:
  - Realms (local cache, 40k entries)
  - Users (local cache, 20k entries)
  - Sessions (distributed, 2 owners)
  - Authentication sessions (distributed, 2 owners)

### Pod Distribution

1. **Anti-Affinity**: Pods spread across different nodes
2. **Topology Spread**: Pods spread across availability zones
3. **Pod Disruption Budget**: Minimum 2 pods always available

## Resource Sizing

### Memory Calculation

Base formula (per pod):
```
Memory = 1250 MB (base + 10k sessions)
       + (sessions beyond 10k) * scaling factor
```

JVM allocation:
- **Heap**: 70% of memory limit
- **Non-Heap**: ~300 MB

### CPU Calculation

```
CPU = (password-based logins per second / 15) vCPU
```

Example: 300 logins/second = 20 vCPU across cluster

### Production Sizing (Per Pod)

| Resource | Request | Limit | Notes |
|----------|---------|-------|-------|
| CPU | 2 cores | 6 cores | Allow bursting |
| Memory | 1250 Mi | 2250 Mi | Handles load spikes |

## Security Architecture

### Pod Security

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

### Network Security

- **NetworkPolicy**: Restricts ingress/egress
- **Ingress**: HTTPS only (TLS termination)
- **Internal**: JGroups ports (7800, 57800) for cluster communication
- **Database**: Restricted to database namespace

### Secret Management

**Development**:
- Kubernetes Secrets (base64 encoded)

**Production**:
- External Secrets Operator
- Integration with cloud secret stores (AWS Secrets Manager, Azure Key Vault, etc.)

## OCM Component Packaging

### Included Artifacts

1. **CRDs** (YAML)
   - `keycloaks.k8s.keycloak.org`
   - `keycloakrealmimports.k8s.keycloak.org`

2. **Operator Deployment** (YAML)
   - Deployment, RBAC, ServiceAccount

3. **Container Images** (OCI)
   - Keycloak Operator: `quay.io/keycloak/keycloak-operator:26.4.5`
   - Keycloak: `quay.io/keycloak/keycloak:26.4.5`

4. **Configurations** (YAML)
   - Minimal configuration
   - Production configuration

### Component Descriptor

```yaml
components:
  - name: github.com/ocm/keycloak
    version: 26.4.5
    resources:
      - type: yaml (CRDs, operator)
      - type: ociImage (container images)
    sources:
      - type: git (keycloak-k8s-resources)
```

## Upgrade Strategy

### Operator Upgrade

1. Update CRDs
2. Update operator deployment
3. Operator manages Keycloak rolling update

### Keycloak Version Upgrade

1. Update image version in Keycloak CR
2. Operator performs rolling update
3. One pod at a time to maintain availability

## Monitoring and Observability

### Metrics

Keycloak exposes Prometheus metrics:

- `keycloak_logins_total`
- `keycloak_registrations_total`
- `jvm_memory_used_bytes`
- `http_server_requests_seconds`

### Health Checks

- **Liveness**: `/health/live`
- **Readiness**: `/health/ready`
- **Startup**: `/health/started`

### Logging

- **Format**: JSON (production) for log aggregation
- **Level**: INFO (production), DEBUG (development)
- **Output**: Console

## Future Enhancements

1. **Multi-Cluster Support**: Cross-datacenter replication
2. **Backup/Restore**: Automated backup operator integration
3. **Custom Themes**: Theme packaging in OCM component
4. **Realm Templates**: Pre-configured realm examples
5. **Performance Tuning**: JVM optimization guide

## References

- [Keycloak Official Documentation](https://www.keycloak.org/documentation)
- [Keycloak Operator Guide](https://www.keycloak.org/operator/installation)
- [Keycloak HA Guide](https://www.keycloak.org/high-availability/multi-cluster/deploy-keycloak-kubernetes)
- [OCM Specification](https://github.com/open-component-model/ocm-spec)
