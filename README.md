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
| `apps/` | One ArgoCD Application per file: `argocd.yaml` (ArgoCD managing itself), `podinfo.yaml`, `csi-secrets-aws.yaml` (Secrets Store CSI driver and AWS provider, wave 0), `identity-demo.yaml` (wave 1), the monitoring apps (`policy-reporter.yaml`, `prometheus.yaml`, `monitoring-config.yaml`, `grafana.yaml`) and `juice-shop.yaml` (no automated sync: see below). |
| `argocd/values.yaml` | Values for the ArgoCD chart. Used by the first install and by `apps/argocd.yaml`. |
| `workloads/podinfo/` | podinfo's Deployment and Service (upstream image for now; Phase 2 switches to the image our pipeline builds and signs). |
| `workloads/juice-shop/` | Phase 3 adversarial workload: OWASP Juice Shop v20.3.0 (commit `f189f521`), deliberately vulnerable. Deployment and ClusterIP Service in namespace `juice-shop`, hardened to pass all 17 policies without exceptions. The image is the placeholder `ACCOUNT_ID.dkr.ecr.eu-west-3.amazonaws.com/forge/juice-shop:TAG`: it must be built from source, signed and attested by `forge-factory` first (not built yet). |
| `workloads/identity-demo/` | Plan 1.7: a service account tied to an IAM role, a `SecretProviderClass` and a pod that prints one Parameter Store secret. `ACCOUNT_ID` in `serviceaccount.yaml` is a placeholder until the AWS account exists; an account ID is not a secret (AWS docs), so the real one may be committed here. |
| `policies/` | Kyverno policies, delivered by `apps/policies.yaml` (wave 1, after Kyverno). Three `ImageValidatingPolicy` files for our ECR images (`ecr-signature.yaml`, `ecr-sbom.yaml`, `ecr-vuln.yaml`, 720h scan window; `ACCOUNT_ID` is a placeholder until the account exists) and 17 `ValidatingPolicy` files for the CIS and Pod Security Standards controls (`pss-*.yaml`, `cis-*.yaml`; see "Pod security policies" below). Accepted by Kyverno 1.19.1 on kind; nothing past that is proven. |
| `policy-tests/` | Fixtures and `run.sh` for the 17 pod security policies: server-side dry runs against a cluster that has Kyverno and the policies. `run-workloads.sh` checks that every manifest below `workloads/` passes the 17 policies. Not synced by ArgoCD (outside `policies/`). |
| `monitoring/` | Phase 2/3 observability: values for Policy Reporter, Prometheus and Grafana (`*-values.yaml`) and `config/dashboard-kyverno.yaml`, the Grafana dashboard JSON in a ConfigMap. Delivered by `apps/policy-reporter.yaml`, `apps/prometheus.yaml` and `apps/monitoring-config.yaml` (wave 2) and `apps/grafana.yaml` (wave 3). See "Monitoring" below. |
| `kyverno/values.yaml` | R2: values for the Kyverno chart 3.9.1 (v1.19.1): ADR-002 sizes, two admission replicas, hard spreading. The IRSA annotation is commented out on purpose: R2 step 3 runs without it, step 4 adds it in a second commit. Used by `apps/kyverno.yaml` (wave 0). WRITTEN, NOT yet tested in ArgoCD. |
| `PARKED.md` | The scope tripwires (R5) and the ideas they parked. Read the ideas after Phase 2 ships. |
| `RUNBOOK.md` | What a confusing refusal from the admission gate really means, and the emergency procedure (from ADR-002). |

## Pod security policies

17 `ValidatingPolicy` files, one per control, so one PolicyReport result maps to one control. Each carries the annotation `forge.dev/controls` with the CIS (Kubernetes Benchmark v1.9 numbering) and PSS control it enforces; `conformity` (Phase 3) will read it. The three `ecr-*` image policies carry the same annotation with `FORGE SC-1` to `SC-3` (supply-chain controls, not CIS numbers).

| Group | Files |
| --- | --- |
| PSS Baseline (8) | `pss-privileged`, `pss-host-namespaces`, `pss-host-ports`, `pss-host-path`, `pss-apparmor`, `pss-selinux`, `pss-proc-mount`, `pss-sysctls` |
| PSS Restricted additions (6) | `pss-privilege-escalation`, `pss-run-as-non-root`, `pss-run-as-user`, `pss-seccomp`, `pss-capabilities`, `pss-volume-types` |
| CIS only (3) | `cis-default-namespace` (5.7.4), `cis-secrets-as-files` (5.4.1), `cis-sa-token` (5.1.6) |

Decisions and limits:
- Action is `[Deny, Audit]`: violations are refused and also appear in PolicyReports.
- Scope: Pod creation, and through autogen Deployments, StatefulSets, DaemonSets, Jobs and CronJobs. Namespaces `kube-system`, `kube-node-lease`, `kube-public`, `kyverno`, `argocd`, `monitoring` and `policy-reporter` are excluded (the Secrets Store CSI driver in `kube-system` is privileged by design; `monitoring` and `policy-reporter` were added on 2026-10-16, see "Monitoring"). On 2026-10-16 the rendered Kyverno 3.9.1 and Argo CD 10.10.3 charts passed all 14 PSS policies; they fail only `cis-sa-token` (the controllers need the API token) and, for Argo CD, `cis-secrets-as-files`. Narrowing the exclusion to those two policies is possible, at the cost that a chart upgrade could then block Kyverno or ArgoCD pods.
- Ephemeral containers (`kubectl debug`) are NOT checked. Kyverno's autogen only works when a policy matches `pods` alone, and matching the `pods/ephemeralcontainers` subresource also needs extra RBAC for the reports controller. Pod updates are not matched either (a pod's spec is immutable).
- `cis-sa-token` has no escape hatch: a workload that needs the API token needs a `PolicyException` in its own namespace.
- Not covered: Windows HostProcess (5.2.11, Linux cluster), RBAC (5.1.x) and NetworkPolicy (5.3.x), which are not pod admission checks; 5.2.1 is met by Kyverno itself.
- `workloads/juice-shop/` passed on the first try but one thing is NOT hardened: `readOnlyRootFilesystem` is `false`, because a read-only root made the app crash at start (its SQLite database `data/juice-shop.sqlite` lives next to the static files in `data/`, and it also writes `ftp/`, `logs/` and `i18n/`); no policy asks for it.
- Workloads in `workloads/` had to change to pass: `podinfo` got `runAsNonRoot` with `runAsUser: 100` (its image user `app` is not numeric) and `automountServiceAccountToken: false`; `identity-demo` got `automountServiceAccountToken: false` (unverified until EKS).

`policy-tests/run-workloads.sh` dry-runs a CREATE of each manifest in `workloads/` in a scratch namespace (the policies match CREATE only, so `apply --dry-run=server` on a workload that already runs would pass anything: the first version of the script did exactly that and a negative control caught it). Result on 2026-10-17 on kind: 6 accepted, 1 skipped (the `SecretProviderClass` needs a CRD the cluster lacks), 0 failed; seven deliberately broken copies of the Juice Shop Deployment (no seccomp, no `runAsNonRoot`, no `automountServiceAccountToken: false`, `default` namespace, capabilities not dropped, privilege escalation allowed, `runAsUser: 0`) were each refused by the named policy.

Juice Shop was first run on kind with its outbound traffic cut (`docker exec <kind-node> iptables -I FORWARD 1 -s <pod CIDR> -o eth0 -j DROP`; cluster-internal traffic keeps working, and the app's attempts to reach the internet showed up as dropped packets). There is no NetworkPolicy for it yet: the EKS network policy agent is not enabled, so one would give false assurance.

Test: with a kind cluster that has Kyverno (chart 3.9.1) and `kubectl apply -f policies/pss-*.yaml -f policies/cis-*.yaml` done, run `policy-tests/run.sh`. 34 violating fixtures must be refused by the named policy and 8 compliant ones accepted. Result on 2026-10-16: 42 of 42, and `podinfo` shows 17 passes in its PolicyReport. Not tested: delivery of these files by ArgoCD, anything on EKS, the cost of the 17 policies on admission latency or memory.

## Monitoring

Installed, not built (R5): Policy Reporter for the per-pod admission state, Prometheus and Grafana for the history. Namespaces `policy-reporter` (the UI) and `monitoring` (Prometheus, Grafana); both are excluded from the pod security policies, because the Prometheus and Policy Reporter pods need the API token (`cis-sa-token`) and, like ArgoCD and Kyverno, they are tools we install but do not build (ADR-002 decision 10).

| Piece | Chart | Notes |
| --- | --- | --- |
| Policy Reporter | `policy-reporter` 3.11.1 (spec said 3.10.0 in September) | UI on, Kyverno plugin, metrics and the chart's own dashboards off. The UI pod has no service account token. |
| Prometheus | `prometheus` 29.37.0 (Prometheus v3.15.0) | Plain Prometheus, no operator, no Alertmanager, no kube-state-metrics, no PVC (emptyDir, 6 h of data, 15 s scrape). Scrapes only the Kyverno admission controller pods (job `kyverno-admission`, port 8000). Hardened to the PSS restricted profile except for the API token it needs for pod discovery. |
| Grafana | `grafana` 13.2.6 (Grafana 13.2.2) from `https://grafana-community.github.io/helm-charts` | The old repo `grafana.github.io/helm-charts` ended at 10.5.15, which is marked deprecated (the chart moved to `grafana-community/helm-charts` on 2026-01-30). Datasource and dashboard come from Git; no sidecar, no plugins, no token. A startup probe (10 minutes) covers the slow first start: it re-runs its migrations on every start. On a busy laptop kind cluster (rotational disk, I/O wait 34 to 76 %) Grafana 13.2.2 still did NOT become Ready in two 10-minute attempts, while on a quiet one it was Ready in under 5 minutes; untested on EKS. Fallbacks if EKS shows the same: a Grafana 12 chart (community chart 11.6.1 = Grafana 12.4.3), or SQLite tuning. |

Dashboard `Forge: Kyverno admission` (folder Forge): replicas answering, allowed versus refused requests per second, refused requests by namespace, admission latency (p50, p95), CIS/PSS results per policy, image policy results per policy. Edit the JSON in `monitoring/config/dashboard-kyverno.yaml`, never in the UI.

Alert (provisioned in `monitoring/grafana-values.yaml`): fewer than 2 admission replicas answering, which is ADR-002 decision 4. It shows in Grafana only (no Alertmanager, no contact point). Measured on kind: after one of two replicas was removed, the alert went Pending after 46 s and Firing after 2 min 47 s (15 s scrape; with the chart's 60 s scrape it took 1 min 39 s and 3 min 42 s), and it cleared about 2 minutes after the replica came back. The second ADR-002 alert, Kyverno webhook configurations missing, is NOT built: it needs kube-state-metrics. Both gaps are accepted in ADR-002 decision 9.

Access: no ingress. `kubectl -n monitoring port-forward svc/grafana 3000:80` (user `admin`, password from `kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d`), `kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080`.

Tested on kind on 2026-10-16: first with Helm and the values files, then end to end through ArgoCD on a fresh cluster (root app, all 11 apps Synced; about 18 minutes, mostly image pulls). ArgoCD delivery findings: sync waves are NOT enforced between separate Applications (the root app does not wait for the health of the Applications it creates), so `policies` first failed with "no matches for kind ValidatingPolicy" and, like `kyverno` (4 retries) and `identity-demo` (3), converged through ArgoCD's automatic retries; a change pushed to Git (the Grafana chart move) reached the cluster within a minute. Making ArgoCD assess Application health was NOT done on purpose: a Degraded `identity-demo` would then block the monitoring waves. Not tested: anything on EKS, resource use on the real nodes, how the dashboard looks (queries were checked through Grafana's API, not by eye), Grafana 13 under ArgoCD (it never became Ready on the busy laptop cluster, see above; the Grafana API checks were made on the quiet Helm cluster and, with the old 12.3.1 pod, under ArgoCD).

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
