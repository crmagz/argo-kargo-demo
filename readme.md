🚀 Argo CD + Argo Rollouts + Kargo Demo

This demo sets up a GitOps-based Kubernetes delivery pipeline using:

- Argo CD for application deployment and visualization
- Argo Rollouts for progressive delivery (canary deployments)
- Kargo for automated stage-based promotions (Dev → Staging → Prod)

⸻

🧩 Overview

The pipeline consists of 3 progressive delivery stages:
	1.	Dev
	2.	Staging
	3.	Production

Each stage uses:

- Argo Rollouts to manage gradual rollout of new versions
- Kargo to promote builds from one stage to the next

⸻

📦 What’s Installed

Component	Description
- Argo CD	GitOps controller and UI for application management
- Argo Rollouts	Progressive delivery using canary and blue-green strategies
- Rollout Extension	Adds rollout dashboard into the Argo CD UI
- Kargo	Automates environment promotion workflows between stages

To install the environment into a K8s cluster run: 

```bash
# Have $GITHUB_TOKEN and $GITHUB_USERNAME exported
chmod +x install.sh
./install.sh
```


⸻

🚦 Promotion Flow
 - A new container image version triggers a Promotion Task in Kargo
 - The dev stage applies the rollout using Argo CD
 - After the canary analysis, a rollout must be manually promoted using:

```bash
kubectl argo rollouts promote kargo-demo-rollout -n kargo-demo-dev
```

Once promoted, Kargo advances the version to staging and prod, following the defined stage templates.

⸻

🚀 Launching the UIs locally

Creating tmux sessions of port forwards
```bash 
tmux new-session -d -s argo-port "kubectl port-forward svc/argocd-server -n argocd 8080:443"
tmux new-session -d -s kargo-port "kubectl port-forward svc/kargo-api -n kargo 3000:443"
```
⸻

🎛️ Viewing the Rollouts

✅ Argo CD UI (with Rollout Extension)
 - Visit: https://localhost:8080
 - Log in with the default admin password (printed after install)
 - Navigate to Applications > kargo-demo-dev (or other stages)
 - Use the “Rollouts” tab to monitor and promote rollout status

📟 Argo Rollouts CLI

Use the kubectl-argo-rollouts CLI to view the rollout status:

```bash
kubectl get po -A | grep argo
```

```bash
kubectl argo rollouts get rollout -n kargo-demo-dev kargo-demo-rollout --watch
```

⸻

🧪 Manual Testing

Trigger new image tags to test the end-to-end flow. Use the CLI to:

 - Monitor rollout progression
 - Promote when prompted (manual gates)
 - Watch the rollout status update in real time

⸻

🧼 Cleanup

Use the provided uninstall.sh script to remove all components:

```bash
./uninstall.sh
```

This will:

- Kill background tmux port-forwards
- Uninstall Helm charts
- Remove Kargo CRDs
- Clean up namespaces and finalizers

⸻

📎 Additional Notes
 - GitHub credentials are injected into Kargo via a Kubernetes Secret
 - Rollout image updates are patched automatically via Kargo’s promotion task
 - Everything is wired via GitOps — the source of truth lives in the Git repo

