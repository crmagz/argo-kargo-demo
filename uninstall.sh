#!/bin/bash

set -euo pipefail

# 🎨 Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}🧹 Starting cleanup of ArgoCD, Argo Rollouts, and Kargo...${NC}"

# 🔪 Kill tmux port-forwarding sessions if they exist
for session in argo-port kargo-port; do
  if tmux has-session -t "$session" 2>/dev/null; then
    echo -e "${YELLOW}==> Killing tmux session: $session${NC}"
    tmux kill-session -t "$session" 2>/dev/null || true
  fi
done

# 🗑️ Delete ApplicationSet and Kargo manifests
echo -e "${YELLOW}==> Deleting ApplicationSet and manifests...${NC}"
kubectl delete applicationset kargo-demo -n argocd --ignore-not-found=true
kubectl delete -f kargo.yml --ignore-not-found=true || true
kubectl delete -f appset.yml --ignore-not-found=true || true

# 🔧 Remove finalizers from Kargo stages
echo -e "${YELLOW}==> Removing finalizers from Kargo stages (if any)...${NC}"
for stage in dev integration staging prod; do
  kubectl patch stage "$stage" -n kargo-demo -p '{"metadata":{"finalizers":[]}}' --type=merge || true
done

# 🔻 Uninstall Helm releases
echo -e "${YELLOW}==> Uninstalling Helm releases...${NC}"
helm uninstall argocd -n argocd || true
helm uninstall argo-rollouts -n argo-rollouts || true
helm uninstall kargo -n kargo || true
helm uninstall cert-manager -n cert-manager || true

# ❌ Delete Kargo-related CRDs
echo -e "${YELLOW}==> Deleting Kargo-related CRDs...${NC}"
kubectl get crds | grep kargo.akuity.io | awk '{print $1}' | xargs -r kubectl delete crd

# 🧼 Delete namespaces
echo -e "${YELLOW}==> Deleting namespaces...${NC}"
kubectl delete namespace argocd --ignore-not-found=true
kubectl delete namespace argo-rollouts --ignore-not-found=true
kubectl delete namespace kargo --ignore-not-found=true
kubectl delete namespace kargo-demo --ignore-not-found=true
kubectl delete namespace cert-manager --ignore-not-found=true

echo -e "\n${GREEN}✅ Cleanup complete!${NC}"