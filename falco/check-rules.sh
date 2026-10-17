#!/usr/bin/env bash
# Validates the Juice Shop rules in falco-values.yaml (the text between the BEGIN RULES and END
# RULES markers) with the pinned Falco image: `falco -V`, no network, no capabilities. It checks
# syntax, field names and macro use. It does NOT check that a rule fires: that needs a cluster
# (falco/README.md). A warning counts as a failure.
#   usage: falco/check-rules.sh [VALUES_FILE]     (default: falco-values.yaml next to this script)
set -u
dir=$(cd "$(dirname "$0")" && pwd)
values=${1:-$dir/falco-values.yaml}
image=docker.io/falcosecurity/falco:0.44.1   # keep equal to the chart's appVersion (apps/falco.yaml)

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
sed -n '/# BEGIN RULES/,/# END RULES/p' "$values" | sed '1d;$d' | sed 's/^    //' > "$tmp/rules.yaml"
if [ ! -s "$tmp/rules.yaml" ]; then echo "no rules found between the markers in $values"; exit 2; fi
chmod 755 "$tmp"; chmod 644 "$tmp/rules.yaml"

out=$(docker run --rm --network none --cap-drop ALL -v "$tmp/rules.yaml":/etc/falco/rules.d/check.yaml:ro \
  --entrypoint falco "$image" -c /etc/falco/falco.yaml \
  -o rules_files[0]=/etc/falco/rules.d/check.yaml -o rules_files[1]= -V /etc/falco/rules.d/check.yaml 2>&1)
status=$?
grep -v 'schema validation\|\[libs\]\|System info\|Falco version\|initialized with\|Loaded plugin' <<<"$out"
echo "rules: $(grep -c '^- rule:' "$tmp/rules.yaml")"
if [ "$status" -ne 0 ] || ! grep -q 'check.yaml: Ok$' <<<"$out"; then echo "FAILED"; exit 1; fi
echo "OK"
