# Argo + Kargo GitOps Demo

## Project Overview

This repository is a **proof-of-concept demo** evaluating Argo CD, Argo Rollouts, and Kargo for GitOps and progressive delivery in a software development lifecycle (SDLC). The target audience is **software engineers** looking to simplify GitOps observability and delivery processes.

### Goals
- Demonstrate multi-stage promotion pipelines (dev -> staging -> prod)
- Showcase progressive delivery with canary rollouts
- Automate environment promotions with verification gates
- Provide a foundation for production-ready GitOps workflows

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│     Dev     │────>│   Staging   │────>│    Prod     │
└─────────────┘     └─────────────┘     └─────────────┘
      │                   │                   │
      v                   v                   v
 Rollout Analysis   Rollout Analysis   Rollout Analysis
 (Web: /health +    (Web: /health +    (Prometheus mem)
  /products)         /products)        product-api + stress
  -> PASS            -> PASS           > 150MB -> ROLLBACK
                          │
                          v
                   Kargo Verification
                   (Web: /health +
                    /products on stable)
```

### Canary Analysis Strategy
- **Dev/Staging**: Web provider analysis checks product-api endpoints (`/health` returns `status: healthy`, `/products` returns `count >= 1`)
- **Prod**: Prometheus memory analysis — a `stress` sidecar (256MB allocation) pushes pod memory above 150MB threshold, triggering auto-rollback
- **Staging Kargo Verification**: Post-deploy HTTP smoke test against the stable service (demonstrates Kargo verification value)
- The 30s pause before analysis gives the canary pods time to start and respond to health checks

### Components
- **Argo CD**: GitOps controller syncing Kubernetes state from Git
- **Argo Rollouts**: Progressive delivery with canary deployment strategy
- **Kargo**: Multi-stage promotion automation with verification gates
- **product-api**: Node.js Express REST API with Redis caching, Prometheus metrics, and health endpoints

### Installed Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Kargo | 1.8.4 | Explicitly pinned |
| Argo CD | Latest (Helm) | Uses `argo/argo-cd` chart |
| Argo Rollouts | Latest (Helm) | Uses `argo/argo-rollouts` chart |
| Rollout Extension | v0.3.4 | UI extension for Argo CD |
| Cert Manager | Latest (Helm) | Uses `jetstack/cert-manager` chart |
| kube-prometheus-stack | Latest (Helm) | Prometheus + Grafana for canary analysis |
| product-api (demo app) | 0.9.0 baseline, ^1.0.0 promotion | Pre-deployed baseline + semver constraint for ECR subscription |
| Redis (Bitnami Legacy) | 7.4.3 | Sidecar for product-api caching |
| polinux/stress | latest | Stress sidecar for prod canary failure |

> **Note**: Consider pinning Helm chart versions for reproducible installations. Check [Argo Helm Charts](https://github.com/argoproj/argo-helm) and [Cert Manager Releases](https://cert-manager.io/docs/releases/) for available versions.

## Repository Structure

```
├── install.sh              # Main installation script
├── uninstall.sh            # Cleanup script
├── appset.yml              # Argo CD ApplicationSet
├── product-api/            # Demo application source
│   ├── Dockerfile          # Node.js 20 Alpine image
│   ├── .dockerignore
│   ├── package.json        # Express, Redis, prom-client, winston
│   └── src/
│       └── index.js        # REST API with /health, /ready, /metrics, /products
├── base/                   # Base Kustomize manifests
│   ├── rollout.yaml        # Argo Rollout (product-api + Redis sidecar, canary strategy)
│   ├── service.yaml        # Kubernetes Service (stable, port 3000 -> 8080)
│   ├── canary-service.yaml # Kubernetes Service (canary traffic)
│   └── analysis-template.yaml  # AnalysisTemplate (web provider: /health + /products)
├── stages/                 # Environment-specific overlays
│   ├── dev/                # Patches namespace arg for analysis
│   ├── staging/            # Patches namespace arg for analysis
│   └── prod/               # Adds stress sidecar + overrides AnalysisTemplate to Prometheus memory check
├── kargo/                  # Kargo resource definitions
│   ├── project.yml         # Kargo Project
│   ├── warehouse.yml       # ECR product-api image subscription
│   ├── promotiontask.yml   # Promotion workflow steps
│   └── stages.yml          # Stage definitions with verification AnalysisTemplates
└── kind/
    └── config.yml          # Kind cluster configuration
```

## Key Files

### product-api (`product-api/`)
A Node.js Express REST API with Redis caching that serves as the demo application:
- **Endpoints**: `/health`, `/ready`, `/metrics`, `/products`, `/products/:id`
- **Redis sidecar**: Runs as a sidecar container (localhost:6379) for caching
- **Prometheus metrics**: Exposes `http_request_duration_seconds`, `http_requests_total`, `cache_hits_total`, etc.
- **ECR repo**: `964108025908.dkr.ecr.us-east-1.amazonaws.com/product-api`

### Kargo Resources (`kargo/`)
Kargo configuration should be managed from files in the `kargo/` directory:

| File | Purpose |
|------|---------|
| `project.yml` | Defines the Kargo project namespace |
| `warehouse.yml` | Subscribes to ECR product-api image updates (semver ^1.0.0) |
| `promotiontask.yml` | 7-step promotion workflow (clone, build, commit, push, sync) |
| `stages.yml` | Stage definitions with web-based verification AnalysisTemplates |

### Base Application (`base/`)
- `rollout.yaml`: product-api + Redis sidecar, canary strategy with 20% -> 50% -> 100% traffic shifting, web-based analysis step with `namespace` arg, Prometheus scrape annotations
- `service.yaml`: NodePort service for stable traffic (port 3000 -> 8080)
- `canary-service.yaml`: ClusterIP service targeting canary pods for analysis verification
- `analysis-template.yaml`: `canary-check` template using web provider to check `/health` (status=healthy) and `/products` (count >= 1), accepts `namespace` arg

### Stage Overlays (`stages/`)
- **dev/staging**: Patch the namespace arg for canary analysis
- **prod**: Patches namespace arg, adds stress sidecar (256MB), and overrides the AnalysisTemplate to use Prometheus memory check instead of web provider (stress sidecar causes memory > 150MB -> rollback)

## Current State & Roadmap

### Completed
- Kind cluster provisioning with Argo CD, Rollouts, and Kargo
- Multi-stage ApplicationSet generating per-environment apps
- Basic promotion workflow with Kustomize image updates
- Kargo resources moved from inline heredocs to `kargo/` directory files
- **product-api** demo application with Redis caching, Prometheus metrics, and health endpoints
- Web provider canary analysis checking `/health` and `/products` endpoints (dev/staging)
- Prometheus memory analysis for prod with stress sidecar causing rollback
- Kargo staging verification with HTTP smoke tests against stable service
- Canary service for targeted traffic during analysis
- Prometheus + Grafana (kube-prometheus-stack) for metrics
- Per-stage namespace arg passed to analysis template via Kustomize patches
- ECR image repository with Kargo Warehouse subscription
- AWS ECR credential management in install script

### TODO

#### Enhanced AnalysisTemplates
Current analysis uses web provider health/product checks (dev/staging) and Prometheus memory (prod). Future improvements could include:

**HTTP success rate verification:**
```yaml
successCondition: result[0] >= 95
query: |
  sum(rate(http_requests_total{status=~"2.."}[5m])) /
  sum(rate(http_requests_total[5m])) * 100
```

**Latency verification (p99):**
```yaml
successCondition: result[0] < 0.5
query: |
  histogram_quantile(0.99,
    rate(http_request_duration_seconds_bucket{namespace="{{args.namespace}}"}[5m])
  )
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
- AWS CLI (authenticated with ECR access)
- argocd CLI
- GitHub credentials (`GITHUB_USERNAME`, `GITHUB_TOKEN`)

### Quick Start
```bash
# Set credentials
export GITHUB_USERNAME=your-username
export GITHUB_TOKEN=your-token
export AWS_ACCOUNT_ID=964108025908  # optional, defaults to this
export AWS_REGION=us-east-1         # optional, defaults to this

# Install everything
./install.sh

# Access UIs
# ArgoCD: https://localhost:8080
# Kargo:  https://localhost:3000
# Grafana: http://localhost:3001

# Test the API
curl http://localhost:30087/health
curl http://localhost:30087/products
```

### ECR Credentials
The install script creates a Kargo image credential secret using a pre-exchanged ECR token (`aws ecr get-login-password`). The token is valid for 12 hours.

**Important**: The `repoURL` in the credential secret must include the full image path (e.g., `964108025908.dkr.ecr.us-east-1.amazonaws.com/product-api`), not just the registry hostname. Kargo matches credentials by prefix against the warehouse subscription URL.

To refresh credentials if the demo runs longer than 12 hours:
```bash
ECR_TOKEN=$(aws ecr get-login-password --region us-east-1)
kubectl delete secret kargo-demo-ecr -n kargo-demo
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: kargo-demo-ecr
  namespace: kargo-demo
  labels:
    kargo.akuity.io/cred-type: image
stringData:
  repoURL: "964108025908.dkr.ecr.us-east-1.amazonaws.com/product-api"
  username: AWS
  password: "${ECR_TOKEN}"
EOF
```

### Baseline Strategy
The base rollout references `product-api:0.9.0`, which Argo CD deploys immediately on sync. This gives all environments running pods and Grafana baseline metrics before any Kargo promotion happens. The Warehouse constraint (`^1.0.0`) discovers `1.0.0` as the new version, creating Freight for the canary promotion demo.

### Promotion Flow
1. Kargo Warehouse detects `product-api:1.0.0` in ECR (newer than baseline 0.9.0)
2. Creates Freight and promotes to dev stage
3. PromotionTask runs: clone -> kustomize -> commit -> push -> sync
4. Argo Rollouts performs canary deployment:
   - Sets canary weight to 20%
   - Pauses 30 seconds (allows canary pods to start)
   - Runs `canary-check` AnalysisTemplate:
     - Dev/Staging: Web provider checks `/health` (status=healthy) and `/products` (count >= 1) -> PASS
     - Prod: Prometheus memory check — stress sidecar pushes memory > 150MB -> FAIL -> auto-rollback
   - On success: continues to 50% -> 100%
5. Staging: After rollout completes, Kargo runs `verify-staging` AnalysisTemplate (HTTP smoke test against stable service)
6. On successful verification, promotion continues to next stage

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

### Test product-api Directly
```bash
# Dev environment
curl http://localhost:30087/health
curl http://localhost:30087/products
curl http://localhost:30087/metrics

# Staging environment
curl http://localhost:30088/health

# Prod environment
curl http://localhost:30089/health
```

## References
- [Argo CD Documentation](https://argo-cd.readthedocs.io/)
- [Argo Rollouts Documentation](https://argoproj.github.io/argo-rollouts/)
- [Kargo Documentation](https://docs.kargo.io/)
