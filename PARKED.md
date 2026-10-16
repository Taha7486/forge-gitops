# PARKED

Ideas that tripped a scope tripwire. Each entry: the need, the date, which installed tool almost covers it. Read this file only after Phase 2 ships. Moved here from the spike repo (`forge-spike-r1`) in Phase 1.

## Scope tripwires (R5)

Any one of these means stop and write the idea below instead of building it:

- A `package.json`, `.html`, `.css`, `.tsx`, `.jsx`, `.vue` or `.svelte` file outside a vendored upstream directory.
- `conformity` gaining `http.ListenAndServe`, `html/template` or a `--serve` flag (HTTP client calls, to Rekor for instance, are fine).
- A Grafana plugin instead of a dashboard JSON.
- Anything Backstage.
- A fifth repository beyond the four in spec §3.2.
- Notes saying "portal", "frontend for" or "my dashboard".

These are written rules checked by hand. A CI check for the first tripwire was considered and dropped on 2026-10-10. Re-check them at every phase exit.

## Parked ideas

## Rekor-monitoring mode for `conformity` (spec §12)

- **Date:** 2026-10-06 (carried over from the spec).
- **Need:** notice unexpected transparency-log entries made with Forge's signing identity.
- **Almost covered by:** the bundle attached to each image already carries its log entry and inclusion proof (ADR-001). Check Sigstore's own `rekor-monitor` before building anything.
- **Constraint:** Rekor v2 has no search index, and Forge pins Rekor v1 for now; a monitor would have to rely on whatever the pinned log supports.
