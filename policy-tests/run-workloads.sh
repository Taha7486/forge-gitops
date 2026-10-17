#!/usr/bin/env bash
# Checks that every manifest below workloads/ passes the 17 pod security policies: a
# server-side dry run of a CREATE against the cluster in the current kubectl context, which
# needs Kyverno and the policies from policies/ (pss-* and cis-*).
#   ok       accepted
#   FAIL     refused (the policy named in the message) or another error
#   skip     the manifest needs a CRD this cluster does not have (the dry run says "no matches
#            for kind"), for example a SecretProviderClass; nothing was checked for it
# Why a scratch namespace: the policies match CREATE only. Against a workload that already runs,
# "apply --dry-run=server" is an UPDATE and would pass anything. So every "namespace:" in a
# manifest is rewritten to "wlcheck" (except "default", which the default-namespace policy must
# see), and the object is created there in a dry run. This is stricter than the live cluster for
# manifests in an excluded namespace (kube-system, kyverno, argocd, monitoring, policy-reporter).
# WORKLOADS_DIR overrides the directory, to test this script with a deliberately broken manifest.
set -u
cd "$(dirname "$0")/.."
dir=${WORKLOADS_DIR:-workloads}
scratch=wlcheck

# A scratch namespace that is still being deleted from the last run would refuse the dry runs.
for _ in $(seq 1 30); do
  [ "$(kubectl get ns "$scratch" -o jsonpath='{.status.phase}' 2>/dev/null)" = Terminating ] || break
  sleep 2
done
made=0
if ! kubectl get ns "$scratch" >/dev/null 2>&1; then kubectl create ns "$scratch" >/dev/null && made=1; fi
trap '[ "$made" -eq 1 ] && kubectl delete ns "$scratch" --wait=true --timeout=90s >/dev/null 2>&1' EXIT

bad=0; ok=0; skipped=0
for f in $(find "$dir" -name '*.yaml' | sort); do
  out=$(sed -E "/namespace:[[:space:]]*default[[:space:]]*\$/! s/^([[:space:]]*namespace:[[:space:]]*)[a-z0-9-]+/\1$scratch/" "$f" \
    | kubectl create --dry-run=server -f - 2>&1)
  if [ $? -eq 0 ]; then
    echo "ok    $f"; ok=$((ok + 1))
  elif grep -q "no matches for kind" <<<"$out" && ! grep -q "Policy forge-" <<<"$out"; then
    echo "skip  $f (CRD missing: $(grep -o 'no matches for kind "[A-Za-z]*"' <<<"$out" | head -1))"; skipped=$((skipped + 1))
  else
    echo "FAIL  $f: $(grep -o 'Policy forge-[a-z-]* failed' <<<"$out" | sort -u | tr '\n' ' ')${out:0:300}"; bad=$((bad + 1))
  fi
done
echo "---"
echo "$ok accepted, $skipped skipped, $bad failed"
[ "$bad" -eq 0 ]
