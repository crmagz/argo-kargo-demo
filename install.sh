#!/bin/bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No color

: "${GITHUB_USERNAME:?Environment variable GITHUB_USERNAME is required}"
: "${GITHUB_TOKEN:?Environment variable GITHUB_TOKEN is required}"
: "${AWS_ACCOUNT_ID:=964108025908}"
: "${AWS_REGION:=us-east-1}"

ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo -e "${YELLOW}Installing ArgoCD + Kargo + Rollouts Demo...${NC}"

# Check prerequisites
for cmd in docker kind kubectl helm aws argocd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}Required command not found: ${cmd}${NC}"
    exit 1
  fi
done

# Create Kind cluster
echo -e "${YELLOW}Creating Kind cluster...${NC}"
kind create cluster --config kind/config.yml --name argo-kargo-demo

# Build and push product-api image
echo -e "${YELLOW}Building product-api image...${NC}"
docker build -t "${ECR_URL}/product-api:1.0.0" ./product-api/

echo -e "${YELLOW}Logging into ECR...${NC}"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URL"

# Create ECR repo (idempotent)
aws ecr describe-repositories --repository-names product-api --region "$AWS_REGION" 2>/dev/null || \
  aws ecr create-repository --repository-name product-api --region "$AWS_REGION"

echo -e "${YELLOW}Pushing product-api image to ECR...${NC}"
docker push "${ECR_URL}/product-api:1.0.0"

# Pre-load images into Kind cluster
echo -e "${YELLOW}Pre-loading images into Kind cluster...${NC}"
docker pull redis:7-alpine 2>/dev/null || true
docker pull polinux/stress:latest 2>/dev/null || true
kind load docker-image "${ECR_URL}/product-api:1.0.0" --name argo-kargo-demo
kind load docker-image redis:7-alpine --name argo-kargo-demo
kind load docker-image polinux/stress:latest --name argo-kargo-demo

# Add Helm repos
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add jetstack https://charts.jetstack.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update argo jetstack prometheus-community

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

# Install Prometheus + Grafana (kube-prometheus-stack)
echo -e "${YELLOW}Installing Prometheus + Grafana...${NC}"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set grafana.service.type=ClusterIP \
  --set prometheus.prometheusSpec.scrapeInterval=3s \
  --wait --timeout 5m

# Generate Kargo credentials
KARGO_PASS=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)
KARGO_HASHED_PASS=$(htpasswd -bnBC 10 "" "$KARGO_PASS" | tr -d ':\n')
KARGO_SIGNING_KEY=$(openssl rand -base64 48 | tr -d "=+/" | head -c 32)

# Install Kargo
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.8.4 \
  --namespace kargo --create-namespace \
  --set api.adminAccount.passwordHash="$KARGO_HASHED_PASS" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --wait --timeout 4m

# Port-forward ArgoCD and Kargo in background via tmux
if command -v tmux >/dev/null 2>&1 && [[ -z "${TMUX:-}" ]]; then
  tmux new-session -d -s argo-port "kubectl port-forward svc/argocd-server -n argocd 8080:443" 2>/dev/null || true
  tmux new-session -d -s kargo-port "kubectl port-forward svc/kargo-api -n kargo 3000:443" 2>/dev/null || true
  tmux new-session -d -s grafana-port "kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3001:80" 2>/dev/null || true
else
  echo "tmux not available or already in tmux session; skipping persistent port-forwards"
fi

# Wait for ArgoCD
echo -n "${YELLOW}Waiting for ArgoCD on localhost:8080..."
for i in {1..30}; do
  if curl -sk https://localhost:8080 >/dev/null 2>&1; then
    echo -e "\n${GREEN}ArgoCD is reachable!${NC}"
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

# Apply ApplicationSet and Kargo Project
echo -e "${YELLOW}Applying ApplicationSet...${NC}"
kubectl apply -f appset.yml

echo -e "${YELLOW}Applying Kargo Project...${NC}"
kubectl apply -f kargo/project.yml

# Wait for Kargo Project to be ready
echo -e "${YELLOW}Waiting for Kargo Project to be ready...${NC}"
kubectl wait --for=condition=Ready project/kargo-demo --timeout=60s

# Apply Git credentials Secret (needs Bash var expansion)
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

# Apply ECR credentials Secret for Kargo Warehouse
echo -e "${YELLOW}Creating ECR credentials for Kargo...${NC}"
ECR_TOKEN=$(aws ecr get-login-password --region "$AWS_REGION")
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
  repoURL: ${ECR_URL}
  username: AWS
  password: ${ECR_TOKEN}
EOF

echo -e "${YELLOW}NOTE: ECR tokens expire every 12 hours. Re-run the ECR credential block if the demo runs longer.${NC}"

# Apply Kargo resources from files (Warehouse, PromotionTask, Stages, AnalysisTemplates)
echo -e "${YELLOW}Applying Kargo resources...${NC}"
kubectl apply -f kargo/warehouse.yml
kubectl apply -f kargo/promotiontask.yml
kubectl apply -f kargo/stages.yml

# Final Output
echo -e "\n${GREEN}Installation complete!${NC}"
echo -e "${GREEN}ArgoCD Admin Password:${NC} $ARGOCD_PASS"
echo -e "${GREEN}Kargo Admin Password:${NC} $KARGO_PASS"
echo -e "\nAccess ArgoCD UI: https://localhost:8080"
echo -e "Access Kargo UI: https://localhost:3000"
echo -e "Access Grafana UI: http://localhost:3001 (admin / admin)"
echo -e "\nTest the API:"
echo -e "  curl http://localhost:30087/health"
echo -e "  curl http://localhost:30087/products"
echo -e "\nTo reattach to port-forward sessions:"
echo -e "  tmux attach -t argo-port"
echo -e "  tmux attach -t kargo-port"
echo -e "  tmux attach -t grafana-port"
