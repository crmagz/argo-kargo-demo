#!/bin/bash

set -euo pipefail

# 🎨 Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No color

: "${GITHUB_USERNAME:?Environment variable GITHUB_USERNAME is required}"
: "${GITHUB_TOKEN:?Environment variable GITHUB_TOKEN is required}"

echo -e "${YELLOW}🚀 Installing ArgoCD + Kargo + Rollouts Demo...${NC}"

# Add Helm repos
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install Cert Manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 3m

# Install ArgoCD
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace --wait --timeout 3m \
  -f - <<EOF
server:
  extensions:
    enabled: true
    extensionList:
      - name: rollout-extension
        env:
          - name: EXTENSION_URL
            value: https://github.com/argoproj-labs/rollout-extension/releases/download/v0.3.4/extension.tar
EOF

# Install Argo Rollouts
helm upgrade --install argo-rollouts argo/argo-rollouts \
  -n argo-rollouts --create-namespace \
  --set dashboard.enabled=true --wait --timeout 3m

# Generate Kargo credentials
KARGO_PASS=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
KARGO_HASHED_PASS=$(htpasswd -bnBC 10 "" "$KARGO_PASS" | tr -d ':\n')
KARGO_SIGNING_KEY=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)

# Install Kargo
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.3.3 \
  --namespace kargo --create-namespace \
  --set api.adminAccount.passwordHash="$KARGO_HASHED_PASS" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --wait --timeout 4m

# Port-forward ArgoCD and Kargo in background via tmux
command -v tmux >/dev/null && {
  tmux new-session -d -s argo-port "kubectl port-forward svc/argocd-server -n argocd 8080:443"
  tmux new-session -d -s kargo-port "kubectl port-forward svc/kargo-api -n kargo 3000:443"
} || echo "⚠️ tmux not found; skipping persistent port-forwards"

# Wait for ArgoCD
echo -n "${YELLOW}⏳ Waiting for ArgoCD on localhost:8080..."
for i in {1..30}; do
  if curl -sk https://localhost:8080 >/dev/null 2>&1; then
    echo -e "\n${GREEN}✅ ArgoCD is reachable!${NC}"
    break
  fi
  sleep 2
done

# Get ArgoCD admin password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Login to ArgoCD CLI
argocd login localhost:8080 --username admin --password "$ARGOCD_PASS" --insecure

# Register GitHub Repo
argocd repo add https://github.com/crmagz/argo-kargo-demo \
  --username "$GITHUB_USERNAME" \
  --password "$GITHUB_TOKEN"

# Install Argo Rollouts CLI
brew list kubectl-argo-rollouts >/dev/null 2>&1 || brew install argoproj/tap/kubectl-argo-rollouts

# Apply dynamic Secret (needs Bash var expansion)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: kargo-demo-repo
  namespace: kargo-demo
  labels:
    kargo.akuity.io/cred-type: git
stringData:
  repoURL: https://github.com/crmagz/argo-kargo-demo
  username: ${GITHUB_USERNAME}
  password: ${GITHUB_TOKEN}
EOF

# Apply remaining manifests with Kargo/Argo templating
cat <<'EOF' | kubectl apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kargo-demo
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - stage: dev
      - stage: integration
      - stage: staging
      - stage: prod
  template:
    metadata:
      name: kargo-demo-{{stage}}
      annotations:
        kargo.akuity.io/authorized-stage: kargo-demo:{{stage}}
    spec:
      project: default
      source:
        repoURL: https://github.com/crmagz/argo-kargo-demo
        targetRevision: stage/{{stage}}
        path: .
      destination:
        server: https://kubernetes.default.svc
        namespace: kargo-demo-{{stage}}
      syncPolicy:
        syncOptions:
        - CreateNamespace=true
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: kargo-demo
spec:
  promotionPolicies:
    - stage: dev
      autoPromotionEnabled: true
    - stage: qa
      autoPromotionEnabled: true
    - stage: prod
      autoPromotionEnabled: false 
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: kargo-demo
  namespace: kargo-demo
spec:
  subscriptions:
  - image:
      repoURL: public.ecr.aws/nginx/nginx
      semverConstraint: ^1.26.0
      discoveryLimit: 5
---
apiVersion: kargo.akuity.io/v1alpha1
kind: PromotionTask
metadata:
  name: demo-promo-process
  namespace: kargo-demo
spec:
  vars:
  - name: gitopsRepo
    value: https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/crmagz/argo-kargo-demo
  - name: imageRepo
    value: public.ecr.aws/nginx/nginx
  steps:
  - uses: git-clone
    config:
      repoURL: ${{ vars.gitopsRepo }}
      checkout:
        - branch: main
          path: ./src
        - branch: stage/${{ ctx.stage }}
          create: true
          path: ./out
  - uses: git-clear
    config:
      path: ./out
  - uses: kustomize-set-image
    as: update-image
    config:
      path: ./src/base
      images:
        - image: ${{ vars.imageRepo }}
          tag: ${{ imageFrom(vars.imageRepo).Tag }}
  - uses: kustomize-build
    config:
      path: ./src/stages/${{ ctx.stage }}
      outPath: ./out
  - uses: git-commit
    as: commit
    config:
      path: ./out
      messageFromSteps:
        - update-image
  - uses: git-push
    config:
      path: ./out
  - uses: argocd-update
    config:
      apps:
        - name: kargo-demo-${{ ctx.stage }}
          sources:
            - repoURL: ${{ vars.gitopsRepo }}
              desiredRevision: ${{ task.outputs.commit.commit }}
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: dev
  namespace: kargo-demo
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: kargo-demo
    sources:
      direct: true
  promotionTemplate:
    spec:
      steps:
      - task:
          name: demo-promo-process
        as: promo-process
  verification:
    analysisTemplates:
    - name: analysis-template-dev
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: analysis-template-dev
  namespace: kargo-demo
spec:
  metrics:
  - name: analysis-template-dev
    provider:
      job:
        spec:
          template:
            spec:
              containers:
              - name: sleep
                image: alpine:latest
                command: [sleep, "10"]
              restartPolicy: Never
          backoffLimit: 1
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: qa
  namespace: kargo-demo
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: kargo-demo
    sources:
      stages:
      - dev
  promotionTemplate:
    spec:
      steps:
      - task:
          name: demo-promo-process
        as: promo-process
  verification:
    analysisTemplates:
    - name: analysis-template-qa        
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: analysis-template-qa
  namespace: kargo-demo
spec:
  metrics:
  - name: analysis-template-qa
    provider:
      job:
        spec:
          template:
            spec:
              containers:
              - name: sleep
                image: alpine:latest
                command: ["/bin/sh", "-c", "exit 1"]
              restartPolicy: Never
          backoffLimit: 1    
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: prod
  namespace: kargo-demo
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: kargo-demo
    sources:
      stages:
      - qa
  promotionTemplate:
    spec:
      steps:
      - task:
          name: demo-promo-process
        as: promo-process
EOF

# Final Output
echo -e "\n${GREEN}✅ Installation complete!${NC}"
echo -e "${GREEN}ArgoCD Admin Password:${NC} $ARGOCD_PASS"
echo -e "${GREEN}Kargo Admin Password:${NC} $KARGO_PASS"
echo -e "\n🌐 Access ArgoCD UI: https://localhost:8080"
echo -e "🌐 Access Kargo UI: https://localhost:3000"
echo -e "\n💡 To reattach to port-forward sessions:"
echo -e "  tmux attach -t argo-port"
echo -e "  tmux attach -t kargo-port"