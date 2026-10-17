# Falco (Phase 4: runtime detection for Juice Shop)

Five custom rules that watch the Juice Shop pod for what its known exploits do at the system call level, shipped with everything needed to run them. Written and tested on a one-node kind cluster on 2026-10-17. **Nothing here has run on EKS**, and the driver on the Amazon Linux 2023 nodes is the biggest open point (see "Not proven").

| File | What it is |
| --- | --- |
| `falco-values.yaml` | Values for the `falco` chart 9.1.0 (Falco 0.44.1, the spec's pin; 0.45.0 has been out since 2026-09-21 and is not used) and the five rules, inline under `customRules` between the `BEGIN RULES` and `END RULES` markers. |
| `falcosidekick-values.yaml` | Values for the `falcosidekick` chart 0.14.0 (image 2.32.0). |
| `check-rules.sh` | Extracts the rules from the values file and validates them with the pinned Falco image (`falco -V`, no network, no capabilities). A warning counts as a failure. Checks syntax and field names only. |
| `../apps/falco.yaml`, `../apps/falcosidekick.yaml` | The ArgoCD Applications. **No automated sync**, like Juice Shop: the driver is untested on the nodes and the load on two nodes is unmeasured, so Falco must not appear by itself in Phases 1 and 2. Sync both by hand in Phase 4. |
| `../monitoring/` | The Prometheus scrape job `falcosidekick`, the Grafana alert rule `Falco rule matched in Juice Shop` and the dashboard `Forge: Falco runtime (Juice Shop)`. |

## The rules

All five only look at containers in the `juice-shop` namespace (`container.id != host and k8s.ns.name = "juice-shop"`). The stock Falco rule set is not loaded.

| Rule | Priority | Fires when | Exploit path it covers |
| --- | --- | --- | --- |
| Juice Shop unexpected process | CRITICAL | any process other than `node` starts in the pod | a shell or tool the attacker brings, or a `kubectl debug` container (the image is distroless: there is no shell to find) |
| Juice Shop sensitive file read | WARNING | `/etc/passwd`, `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers`, `/proc/*/environ`, `/root/.ssh`, `/root/.aws` is opened for reading (processes named `runc:...` are skipped: runc reads `/etc/passwd` at every container start) | the XXE challenge ("XXE Data Access") |
| Juice Shop contacts the metadata address | CRITICAL | a `connect` to the link-local range `169.254.0.0/16` (or IPv6 `fd00:ec2::254`) | server-side request forgery (profile image URL) toward the cloud metadata service. The attempt is what counts, even if it fails. |
| Juice Shop writes outside its data directories | ERROR | a file under `/juice-shop/` is opened for writing outside `data/`, `logs/`, `i18n/` and the profile picture directory, or one of seven files the app rewrites at start is written when the process is more than 5 minutes old | the zip-slip challenge (arbitrary file write), including the canonical target `ftp/legal.md` |
| Juice Shop unexpected listener | CRITICAL | a `listen` on a TCP port other than 3000 | a bind shell or reverse shell tool |

The write allow-list was measured, not guessed. Juice Shop v20.3.0 on kind writes: the SQLite database and its journal (`data/`), the access log (`logs/`), 44 translation files at start (`i18n/`), profile pictures (`.../images/uploads/`) and, at every start, `ftp/legal.md`, `.well-known/csaf/provider-metadata.json`, `frontend/dist/frontend/index.html`, `assets/private/threejs-demo.html`, `assets/public/images/hackingInstructor.png`, `assets/public/images/chatbotAvatar.png` and `assets/public/videos/owasp_promo.vtt`. Start-up took about 70 s on kind. **Re-measure when the Juice Shop version changes**: a new version that writes another file at start will alert on every pod start.

## Design decisions (2026-10-17)

- **Driver:** modern eBPF, least privileged (capabilities `BPF`, `PERFMON`, `SYS_RESOURCE`, `SYS_PTRACE`, not a privileged container). Needs kernel 5.8 or newer with BTF and ring buffer support ([Falco docs](https://v0-37.falco.org/docs/event-sources/kernel/)).
- **Nothing is downloaded at run time:** `falcoctl` is off (the Falco image already contains the container plugin) and `falco.rules_files` lists only our rules, so the image's stock rule file is not read. `falco.config_files: []` is needed because the image's own `config.d` fragment loads the container plugin a second time and Falco refuses to start ("found another plugin with name container").
- **Only the containerd socket is mounted** (no Docker, Podman, CRI-O or LXC engines), and no k8s-metacollector pod: the container plugin supplies `k8s.ns.name` and `k8s.pod.name`.
- **Alerts:** Falco posts JSON to Falcosidekick, which exposes `falcosecurity_falcosidekick_falco_events_total` (labels `rule`, `priority_raw`, `k8s_ns_name`, `k8s_pod_name`, plus `proc_name` from `extralabels`). Prometheus scrapes it (15 s); Grafana alerts on it. **No Alertmanager and no contact point** (R5 and ADR-002 decision 9): an alert shows in Grafana, Alerting, and in the dashboard's alert list. The spec said "Alertmanager and Grafana"; nothing would receive an Alertmanager alert, so it was left out.
- **The namespace `falco` is excluded from the 17 pod security policies** (all 17 files): the driver needs host mounts and capabilities. Checked on kind: a privileged pod with `hostPID` and a `hostPath` volume is admitted in `falco` and refused in another namespace; `policy-tests/run.sh` still gives 42 of 42.
- **The alert expression is not `increase()`.** Falcosidekick creates a counter with its first event, and Prometheus' `increase()` ignores the first sample of a series, so the first event of every new (rule, pod) pair would never alert. The Grafana rule uses `(sum - sum offset 1m) or (sum unless sum offset 1m)` instead. Shown on kind for a new pod: the expression was 1 at the first poll after the attack, while `increase()` stayed at `no-series`, then 0, for a minute. Cost: after a Falcosidekick restart the counters restart too, and the expression can lag by up to a minute for rules that had fired before.
- **Helm's `tpl` runs over the Grafana alert values**, so Grafana's own `{{ $labels.rule }}` in the alert summary is wrapped in Go raw strings (`{{`...`}}`); the first attempt failed to render.
- **Falcosidekick's own labels:** it already labels `k8s_pod_name`; listing `k8s.pod.name` again in `extralabels` makes it panic at start (duplicate label names).

## What was tested (kind, 2026-10-17)

Cluster: one node, Kubernetes 1.35.8, host kernel 7.0, Kyverno 1.19.1 with the 17 policies, Prometheus (repo values), Falco and Falcosidekick installed with Helm from the values in this directory, and the upstream Juice Shop image by digest (`sha256:cea5a4af...`, swapped in on kind only) with pod egress cut as in session 19.

| Check | Result |
| --- | --- |
| `check-rules.sh` on the clean rules; four deliberate breaks (nonexistent field, deprecated `evt.dir`, no markers, syntax error) | OK; each break refused (exit 1, 1, 2, 1) |
| Falco starts under the 17 policies with the modern eBPF driver in least-privileged mode | Running, rules loaded, 0 restarts |
| Baseline: container creation, start-up, normal use (browse, search, API reads, login, register, PDF upload, profile picture upload) | No event from the app. Only kind's own container-setup hook alerts at creation (see below). |
| XXE upload of `file:///etc/passwd` (the response leaks it) | sensitive file read, `node` |
| SSRF through the profile image URL to `169.254.169.254` | contacts the metadata address, `node`, `10.244.0.x -> 169.254.169.254:80` |
| Zip-slip writing a new file in `ftp/` | writes outside its data directories, `node` |
| Zip-slip overwriting `ftp/legal.md` | silent in the first 5 minutes after start (by design), alert after 5 minutes |
| `kubectl debug` ephemeral busybox container: shell, `id`, listener on 4444, `cat /proc/1/environ` | unexpected process, sensitive file read (`id` reads `/etc/passwd`), unexpected listener, sensitive file read |
| The same shell, `/etc/passwd` read and listener in a `kube-system` pod | no event (scoping) |
| Mutation run 1: all five detections broken at once (`vfork` instead of `execve`, `/etc/passwdx`, `169.253.0.0/16`, `/juice-shopx/`, `fd.sport = 3000`) | all five attacks silent; with the unmodified rules the same suite fires all five |
| Mutation run 2: six exclusions broken at once (runc skip, 5-minute guard, `i18n/`, `data/`, `logs/`, uploads) | each one produced events from the app's own normal behaviour |
| Prometheus | scrapes Falcosidekick (`up` 1); event visible in the counter within one 15 s scrape |
| The alert expression against real Prometheus data, for the first event of a new pod | 1 at the first poll; a plain `increase()` stayed at `no-series`, then 0 |
| Grafana 13.2.2 started alone in Docker with the exact provisioning files the chart renders from the repo values (quiet disk, healthy after about 4 minutes) | datasource, both dashboards (folder Forge, four Falco panels) and both alert rules accepted; the alert summary kept its `{{ $labels.rule }}` placeholders |
| The same Grafana with a throwaway fake Prometheus that returns one vector on demand (tests the reduce and threshold steps and the timing, not the PromQL) | idle `Normal (NoData)`; Alerting at the next 10 s evaluation with labels `rule` and `k8s_pod_name`; back to Normal at the next evaluation after the vector disappeared |
| Resource use (`crictl stats`, idle) | Falco about 50 MB and 4 to 5 % of one core; Falcosidekick about 17 MB; Juice Shop about 94 MB |

## Findings and limits

- **Falco is blind to containers that were already running when it (re)starts, on kind.** After a Falco restart, or even a rules hot reload, events from the existing Juice Shop pod showed `container_id=host`, `proc=<NA>`, `pid=-1`, so no rule scoped to the namespace fired; the SSRF that alerted before the restart was silent. A pod created after Falco started is seen. Falco logs "disabled BPF iterators (not running in the root PID namespace)" and the chart does not set `hostPID`. Adding `hostPID: true` by hand changed nothing on kind, which proves little: the kind node is itself a container. **Check on EKS in Phase 4:** restart the Falco DaemonSet, then run the SSRF against the running pod. If it is silent, the DaemonSet needs `hostPID: true` (the chart does not expose it, so it would take a Kustomize patch) or Juice Shop must be restarted after every Falco change.
- **kind noise:** at every container creation kind's own OCI hook (`mount-product-files.sh`, `jq`, `cp`, `mount`) runs inside the container and trips "unexpected process" and "sensitive file read". It does not exist on EKS. The dashboard table says so.
- **Silent by design:** a write to one of the seven boot files in the first 5 minutes after the process starts (the guard uses `proc.duration`; it assumes start-up finishes within 5 minutes, which took about 70 s on kind and may take longer on a loaded node).
- **Not exercised:** `/etc/shadow`, `/etc/gshadow`, `/etc/sudoers`, `/root/.ssh` and `/root/.aws` (the test pod is not root); the IPv6 metadata address; any exploit that reads files through the app other than XXE.
- **Demo 8:** Juice Shop's image has no shell, so "spawn a shell in the container" works through an ephemeral debug container (`kubectl debug -it POD --image=busybox --target=juice-shop`), which the 17 admission policies do not cover (see the README, "Pod security policies"). That makes a good pair: admission cannot see it, Falco can. The real exploits for the demo are the XXE upload, the profile-image SSRF and the zip upload; the safety mode of Juice Shop did not block any of them in a Kubernetes pod without extra configuration.
- **Grafana inside the kind cluster never became Ready** (two attempts of 10 minutes, killed by the startup probe, I/O pressure 65 to 88 %; the same laptop effect as session 18), so the alert and the dashboard were checked in a standalone Grafana instead (table above). Alone on a quiet disk its migrations took 7 seconds. Still open: the full chain Falco, Falcosidekick, Prometheus and Grafana in one running cluster (measured in pieces: Falco to Prometheus in under 15 s, Grafana's reaction within one 10 s evaluation, so about 25 s worst case), and how the dashboard looks (checked through the API only).
- **Not proven:** the kernel driver on the Amazon Linux 2023 EKS nodes (kind used host kernel 7.0), the load on two nodes (Falco measured about 50 MB and 4 to 5 % of a core with Juice Shop at one full core, on one node), the Falco requests of 100m and 256Mi (a guess; the measurement suggests lower), ArgoCD delivery of the two apps (`skipTests` on the Falcosidekick app is unverified), and the hostPID question above.

## Reproducing the attacks (kind, upstream image)

From the kind node (`docker exec <node> curl ...`), with `IP` the pod IP and `TOKEN` from `POST /rest/user/login`:

- XXE: upload `<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><trick>&xxe;</trick>` as `x.xml` to `POST /file-upload`.
- SSRF: `POST /profile/image/url` with the cookie `token=$TOKEN` and the form field `imageUrl=http://169.254.169.254/latest/meta-data/`.
- Zip-slip: a zip with the entry `../../ftp/new-file.txt` (or `../../ftp/legal.md`) uploaded to `POST /file-upload`. Copy the zip into the node through stdin (`docker exec -i NODE sh -c 'cat > /tmp/x.zip' < x.zip`); `docker cp` into the node's tmpfs `/tmp` silently puts it out of sight.
- Ephemeral shell: `kubectl -n juice-shop debug POD --image=busybox:1.37 --target=juice-shop -i -- sh`.
