#!/usr/bin/env bash
# Tests the registry policy (forge-ecr-registry, FORGE SC-4) on its own, with a server-side
# dry run, so nothing is created. Needs Kyverno. It applies ONLY this policy, with ACCOUNT_ID
# replaced by 123456789012 (what the fixtures use), and deletes it at the end. Why separate
# from run.sh: the fixtures there use the upstream podinfo image, which this policy refuses.
# The fixtures carry the hardening the 17 CIS/PSS policies demand (as pass/compliant.yaml does),
# so the result is the same with or without them; each fail fixture breaks only the registry rule.
# Do NOT run it with the three ecr-* policies installed: they would try to verify the images.
#   registry/pass/*.yaml                        must be accepted
#   registry/fail/forge-ecr-registry--*.yaml    must be refused, and the message must name the policy
set -u
cd "$(dirname "$0")"
kubectl get ns pt >/dev/null 2>&1 || kubectl create ns pt >/dev/null
sed 's/ACCOUNT_ID/123456789012/g' ../policies/forge-ecr-registry.yaml | kubectl apply -f - >/dev/null || exit 1
trap 'kubectl delete -f ../policies/forge-ecr-registry.yaml >/dev/null 2>&1' EXIT
# The webhook is registered a moment after the policy is applied.
for _ in $(seq 1 30); do
  kubectl get validatingpolicy forge-ecr-registry -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null | grep -q true && break
  sleep 2
done
sleep 5

bad=0
for f in registry/pass/*.yaml; do
  out=$(kubectl create --dry-run=server -f "$f" 2>&1)
  if [ $? -eq 0 ]; then echo "ok    $f"; else echo "FAIL  $f (expected accepted): $out"; bad=$((bad + 1)); fi
done
for f in registry/fail/*.yaml; do
  out=$(kubectl create --dry-run=server -f "$f" 2>&1)
  if [ $? -ne 0 ] && grep -q "Policy forge-ecr-registry failed" <<<"$out"; then
    echo "ok    $f"
  else
    echo "FAIL  $f (expected refused by forge-ecr-registry): $out"; bad=$((bad + 1))
  fi
done
echo "---"
echo "$(ls registry/pass | wc -l) pass fixtures, $(ls registry/fail | wc -l) fail fixtures, $bad failed"
[ "$bad" -eq 0 ]
