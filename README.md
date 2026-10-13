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

Prove GitOps: change `PODINFO_UI_MESSAGE` in `workloads/podinfo/deployment.yaml`, push, and wait. ArgoCD polls Git on a timer (default 120 s plus up to 60 s jitter), so the wait depends on where in that cycle the push lands. Measured on kind: 211 s and 35 s.

After the bootstrap, change Git, never the cluster: `helm list` still shows the release at revision 1 because ArgoCD took it over without a Helm upgrade, so a manual `helm upgrade` would fight ArgoCD.

## Status

Tested on a local kind cluster (Kubernetes 1.35.8, one node) on 2026-10-13, following the bootstrap above: ArgoCD installed by hand with Helm, then `root-app.yaml` applied. Result: `root`, `argocd` and `podinfo` were all Synced and Healthy within 60 s, no ArgoCD pod restarted, and the `argocd` app manages 43 resources of its own release. The chart's `redis-secret-init` hook job ran a second time when ArgoCD synced (it completed, nothing restarted). Changing the message in Git reached the running pod without any `kubectl` (211 s), and the revert did too (35 s). Idle memory of ArgoCD was about 244 MB in total against 640 Mi requested (one snapshot).

Not proven: anything on EKS (node sizes, IRSA, ECR pulls), ArgoCD's behaviour under load, and a Git change made by a different workflow than a manual push.
