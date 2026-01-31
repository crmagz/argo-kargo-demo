# Argo + Kargo GitOps Demo

## Project Overview

This repository is a **proof-of-concept demo** evaluating Argo CD, Argo Rollouts, and Kargo for GitOps and progressive delivery in a software development lifecycle (SDLC). The target audience is **software engineers** looking to simplify GitOps observability and delivery processes.

### Goals
- Demonstrate multi-stage promotion pipelines (dev → staging → prod)
- Showcase progressive delivery with canary rollouts
- Automate environment promotions with verification gates
- Provide a foundation for production-ready GitOps workflows

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│     Dev     │────▶│   Staging   │────▶│    Prod     │
└─────────────┘     └─────────────┘     └─────────────┘
      │                   │                   │
      ▼                   ▼                   ▼
 AnalysisTemplate   AnalysisTemplate   AnalysisTemplate
 (Prometheus mem)   (Prometheus mem)   (Prometheus mem)
  nginx ~20MB        nginx ~20MB        nginx + stress sidecar
  < 150MB PASS       < 150MB PASS       > 150MB FAIL → ROLLBACK
```

### Canary Analysis Strategy
Prometheus-based memory analysis replaces hardcoded failures:
- **Dev/Staging**: nginx alone uses ~20MB per pod, well under the 150MB threshold
- **Prod**: A `stress` sidecar (256MB allocation) pushes pod memory above threshold, triggering auto-rollback
- kube-prometheus-stack scrapes cAdvisor metrics (`container_memory_working_set_bytes`) from kubelet
- The 30s pause before analysis gives Prometheus 2+ scrape cycles (15s default interval)

### Components
- **Argo CD**: GitOps controller syncing Kubernetes state from Git
- **Argo Rollouts**: Progressive delivery with canary deployment strategy
- **Kargo**: Multi-stage promotion automation with verification gates

### Installed Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Kargo | 1.8.4 | Explicitly pinned |
| Argo CD | Latest (Helm) | Uses `argo/argo-cd` chart |
| Argo Rollouts | Latest (Helm) | Uses `argo/argo-rollouts` chart |
| Rollout Extension | v0.3.4 | UI extension for Argo CD |
| Cert Manager | Latest (Helm) | Uses `jetstack/cert-manager` chart |
| kube-prometheus-stack | Latest (Helm) | Prometheus + Grafana for canary analysis |
| nginx (demo app) | ^1.26.0 | Semver constraint for image subscription |
| polinux/stress | latest | Stress sidecar for prod canary failure |

> **Note**: Consider pinning Helm chart versions for reproducible installations. Check [Argo Helm Charts](https://github.com/argoproj/argo-helm) and [Cert Manager Releases](https://cert-manager.io/docs/releases/) for available versions.

## Repository Structure

```
├── install.sh              # Main installation script
├── uninstall.sh            # Cleanup script
├── appset.yml              # Argo CD ApplicationSet
├── base/                   # Base Kustomize manifests
│   ├── rollout.yaml        # Argo Rollout (canary strategy with analysis)
│   ├── service.yaml        # Kubernetes Service (stable)
│   ├── canary-service.yaml # Kubernetes Service (canary traffic)
│   └── analysis-template.yaml  # AnalysisTemplate for canary verification
├── stages/                 # Environment-specific overlays
│   ├── dev/                # Patches namespace arg for analysis
│   ├── staging/            # Patches namespace arg for analysis
│   └── prod/               # Adds stress sidecar + namespace arg patch
├── kargo/                  # Kargo resource definitions
│   ├── project.yml         # Kargo Project
│   ├── warehouse.yml       # Image source subscription
│   ├── promotiontask.yml   # Promotion workflow steps
│   └── stages.yml          # Stage definitions with AnalysisTemplates
└── kind/
    └── config.yml          # Kind cluster configuration
```

## Key Files

### Kargo Resources (`kargo/`)
Kargo configuration should be managed from files in the `kargo/` directory:

| File | Purpose |
|------|---------|
| `project.yml` | Defines the Kargo project namespace |
| `warehouse.yml` | Subscribes to nginx image updates (semver ^1.26.0) |
| `promotiontask.yml` | 7-step promotion workflow (clone, build, commit, push, sync) |
| `stages.yml` | Stage definitions with AnalysisTemplates for verification |

### Base Application (`base/`)
- `rollout.yaml`: Canary strategy with 20% → 50% → 100% traffic shifting, includes Prometheus-based analysis step with `namespace` arg
- `service.yaml`: NodePort service for stable traffic
- `canary-service.yaml`: Service targeting canary pods for analysis verification
- `analysis-template.yaml`: `canary-check` template using Prometheus provider to query pod memory (`container_memory_working_set_bytes`), accepts `namespace` arg

## Current State & Roadmap

### Completed
- Kind cluster provisioning with Argo CD, Rollouts, and Kargo
- Multi-stage ApplicationSet generating per-environment apps
- Basic promotion workflow with Kustomize image updates
- Kargo resources moved from inline heredocs to `kargo/` directory files
- Canary analysis with auto-rollback integrated into rollout strategy
  - `canary-check` AnalysisTemplate uses Prometheus to query pod memory
  - Rollout pauses at 20%, runs analysis, then continues to 50% → 100%
  - Prod stage adds stress sidecar (256MB) causing memory threshold breach → auto-rollback
- Canary service added for targeted traffic during analysis
- Prometheus + Grafana (kube-prometheus-stack) for metrics-based canary verification
- Per-stage namespace arg passed to analysis template via Kustomize patches

### TODO

#### Enhanced AnalysisTemplates
Current analysis uses Prometheus memory queries. Future improvements could include:

**HTTP success rate verification:**
```yaml
successCondition: result[0] >= 95
query: |
  sum(rate(http_requests_total{status=~"2.."}[5m])) /
  sum(rate(http_requests_total[5m])) * 100
```

**Integration test verification (Job provider):**
```yaml
provider:
  job:
    spec:
      template:
        spec:
          containers:
          - name: tests
            image: your-test-image:latest
            command: ["/bin/sh", "-c"]
            args: ["curl -f http://service:3000/health"]
```

**Webhook-based verification:**
```yaml
provider:
  web:
    url: https://api.example.com/deployments/verify
    headers:
      - key: Authorization
        value: "Bearer {{args.token}}"
successCondition: result.approved == true
```

## Development Workflow

### Prerequisites
- Docker
- Kind
- kubectl
- Helm
- GitHub credentials (`GITHUB_USERNAME`, `GITHUB_TOKEN`)

### Quick Start
```bash
# Set credentials
export GITHUB_USERNAME=your-username
export GITHUB_TOKEN=your-token

# Install everything
./install.sh

# Access UIs
# ArgoCD: https://localhost:8080
# Kargo:  https://localhost:3000
```

### Promotion Flow
1. Kargo Warehouse detects new nginx image
2. Creates Freight and promotes to dev stage
3. PromotionTask runs: clone → kustomize → commit → push → sync
4. Argo Rollouts performs canary deployment:
   - Sets canary weight to 20%
   - Pauses 30 seconds (allows 2+ Prometheus scrape cycles)
   - Runs `canary-check` AnalysisTemplate (queries pod memory via Prometheus)
   - Success condition: max pod memory < 150MB
   - Dev/Staging: nginx ~20MB → PASS
   - Prod: nginx + stress sidecar ~280MB → FAIL → auto-rollback
5. On successful rollout, promotion continues to next stage

### Manual Rollout Promotion
If a rollout is paused or you want to skip analysis:
```bash
kubectl argo rollouts promote kargo-demo-rollout -n kargo-demo-dev
```

### Watch Rollout Progress
```bash
kubectl argo rollouts get rollout kargo-demo-rollout -n kargo-demo-dev --watch
```

## Coding Guidelines

### Kargo Resources
- Define all Kargo resources in `kargo/` directory as separate YAML files
- Use consistent naming: `{resource-type}.yml`
- Keep PromotionTask steps atomic and reusable

### Analysis Templates
- Name templates descriptively: `analysis-template-{stage}` or `analysis-{purpose}`
- Set appropriate `backoffLimit` and `ttlSecondsAfterFinished`
- Use `successCondition` for metrics-based providers
- Include meaningful failure messages

### Stage Configuration
- Each stage should define `requestedFreight` with upstream origin
- Include `verification` block with analysis template reference
- Use `promotionTemplate` referencing shared PromotionTask

## Troubleshooting

### Check Kargo Status
```bash
kubectl get warehouses,stages,freight,promotions -n kargo-demo
```

### View Promotion Logs
```bash
kubectl logs -n kargo-demo -l kargo.akuity.io/promotion
```

### Debug Analysis Runs
```bash
kubectl get analysisrun -n kargo-demo-dev
kubectl describe analysisrun <name> -n kargo-demo-dev
```

## References
- [Argo CD Documentation](https://argo-cd.readthedocs.io/)
- [Argo Rollouts Documentation](https://argoproj.github.io/argo-rollouts/)
- [Kargo Documentation](https://docs.kargo.io/)
