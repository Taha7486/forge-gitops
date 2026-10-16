#!/usr/bin/env bash
# Runs every fixture against the cluster in the current kubectl context with a server-side
# dry run, so nothing is created. Needs Kyverno and the 17 policies in policies/ applied.
#   pass/*.yaml                        must be accepted
#   fail/<policy>--<case>.yaml         must be refused, and the message must name <policy>
# Each fail fixture is the compliant pod plus one violation, so a refusal comes from the
# policy in the file name. The privileged fixtures also trip forge-pss-privilege-escalation:
# the API server forces allowPrivilegeEscalation to true on a privileged container.
set -u
cd "$(dirname "$0")"
kubectl get ns pt >/dev/null 2>&1 || kubectl create ns pt >/dev/null

bad=0
for f in pass/*.yaml; do
  out=$(kubectl create --dry-run=server -f "$f" 2>&1)
  if [ $? -eq 0 ]; then echo "ok    $f"; else echo "FAIL  $f (expected accepted): $out"; bad=$((bad + 1)); fi
done
for f in fail/*.yaml; do
  name=$(basename "$f" .yaml); policy=${name%%--*}
  out=$(kubectl create --dry-run=server -f "$f" 2>&1)
  if [ $? -ne 0 ] && grep -q "Policy $policy failed" <<<"$out"; then
    echo "ok    $f"
  else
    echo "FAIL  $f (expected refused by $policy): $out"; bad=$((bad + 1))
  fi
done
echo "---"
echo "$(ls pass | wc -l) pass fixtures, $(ls fail | wc -l) fail fixtures, $bad failed"
[ "$bad" -eq 0 ]
