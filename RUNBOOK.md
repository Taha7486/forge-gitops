# RUNBOOK — confusing refusals from the admission gate

Moved here from the `forge-spike-r1` README in Phase 1. The reasoning behind it is in ADR-002 (decision 11 and Addendum 1; kept in the private Forge docs repo). The timings were measured in the spike on a kind cluster; the first real numbers on EKS come with the R3e cloud checks.

| What you see | What it really means | What to do |
| --- | --- | --- |
| "no valid signature" or "missing or unverified attestation", in about 2 s | Most likely Sigstore's TUF service was unreachable (DNS failure or refused connection) for an admission controller that **just started**, not a bad image. Running replicas keep verifying while TUF is down. | Read the admission controller log; if it names the TUF address or DNS, retry once |
| The same message after about 30 s | The TUF service is hanging | Check the service; new or restarted replicas stay blocked until it recovers, running pods are fine |
| "error: failed to evaluate policy ... dial tcp ..." | The registry or its download servers are unreachable | Check registry access and the egress allowlist |
| "no valid signature" after about 8 s on a new image | The image really is not signed by the pipeline | Fix it in CI |
| Any refusal | The policy named is only the first of the three to answer, not necessarily the only reason | Read the log for the full cause |
| Everything is refused, including simple pods ("failed calling webhook ... connection refused") | Kyverno is down or unreachable and `Fail` is on | Check the 2 admission replicas and wait a few seconds. If it persists, use the emergency procedure below |

Read the log with `kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller | cat`. A webhook timeout, a TUF or DNS error or a registry rate limit is not a deny.

## Emergency procedure (tested in R3e)

Deleting the Kyverno webhook configurations does **not** help while Kyverno runs (they come back in 2 s). Under ArgoCD, scaling the deployment by hand also drifts from Git: scale it back before ArgoCD's next sync or turn auto-sync off for the `kyverno` app first (not tested here).

1. `kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=0` (the webhooks disappear in about 5 s).
2. Repair what is broken.
3. `kubectl -n kyverno scale deploy kyverno-admission-controller --replicas=2` (Ready in about 45 s).

**The gate is open while the controller is scaled to 0: unsigned images are admitted.** Emergency use only, and scale back to 2 as soon as possible.
