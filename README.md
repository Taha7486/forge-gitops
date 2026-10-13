# forge-gitops

What the Forge cluster should look like, written as files. ArgoCD reads this repo and makes the cluster match it. Nothing here is applied with `kubectl apply` except the two bootstrap steps below.

## Boundary

- Terraform (`forge-infra`) owns anything that has an AWS ARN: network, EKS, nodes, IAM roles, ECR.
- ArgoCD (this repo) owns anything that has a Kubernetes API group: the apps, and later Kyverno and its policies.
- Policies live in Git and are never applied by hand.

The only things done by hand are the first install of ArgoCD and the root app, because ArgoCD cannot install itself from nothing.

## Layout

| Path | What it is |
| --- | --- |
| `bootstrap/root-app.yaml` | The one object applied by hand. Watches `apps/`. |
| `apps/` | One ArgoCD Application per file: `argocd.yaml` (ArgoCD managing itself) and `podinfo.yaml`. |
| `argocd/values.yaml` | Values for the ArgoCD chart. Used by the first install and by `apps/argocd.yaml`. |
| `workloads/podinfo/` | podinfo's Deployment and Service (upstream image for now; Phase 2 switches to the image our pipeline builds and signs). |
| `PARKED.md` | Ideas parked by the scope tripwires. Read it after Phase 2 ships. |

## Pins

Argo CD v3.5.5, installed from the `argo-cd` chart 10.10.3 of `https://argoproj.github.io/argo-helm` (a community-maintained chart). Kubernetes 1.35. If one of these changes, change `apps/argocd.yaml` and the install command together.

## Bootstrap (each session, after the cluster exists)

```
helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version 10.10.3 -n argocd --create-namespace -f argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server
kubectl apply -f bootstrap/root-app.yaml
```

The release name must stay `argocd`: `apps/argocd.yaml` uses the same name so ArgoCD can take over the release it was installed with.

Look at it: `kubectl -n argocd port-forward svc/argocd-server 8080:443`, then open `https://localhost:8080` (self-signed certificate). No load balancer, no ingress.

Prove GitOps: change `PODINFO_UI_MESSAGE` in `workloads/podinfo/deployment.yaml`, push, and wait. ArgoCD checks Git about every 3 minutes (default 120 s plus up to 60 s jitter).

## Status

Not run on any cluster yet. Checked offline: the ArgoCD chart renders with `argocd/values.yaml` (`helm template`, no Dex or notifications), the chart keys exist at the pinned version, podinfo's port, probes and `PODINFO_UI_MESSAGE` match its own chart at 6.15.0, and the Application fields follow the Argo CD docs. Not proven: that ArgoCD cleanly adopts the release installed by hand and then manages itself, the resource requests (estimates, to be tuned from measured usage), and the sync of podinfo.
