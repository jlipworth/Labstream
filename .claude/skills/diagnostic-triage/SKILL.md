---
name: diagnostic-triage
description: Preprocess and triage Labstream headset evidence bundles and app diagnostic JSONL, including repeated evidence pulls. Use whenever headset logs or app diagnostics must be read after a reproduction, especially before opening rotated JSONL files. Runs deterministic deduplication and bounded extraction first; raw logs are escalation-only.
---

# Triage Labstream diagnostics without flooding context

## Mandatory first pass

For a headset evidence bundle:

```sh
scripts/diagnostics-summarize.py build/headset-evidence/<bundle> --auto-baseline
```

The current parser covers app-owned `app-diagnostics.jsonl*` inside headset bundles. It inventories other bundle files but does not interpret unified logs, crash bodies, or free-form reports yet. If there are no supported sources, treat the packet as incomplete rather than evidence that nothing happened.

Read only:

1. `analysis/triage.md`
2. `analysis/summary.json`
3. For a repeated pull, the bounded `analysis/novel-events.jsonl`

Do **not** cat, glob-read, or paste a diagnostics directory, every rotated JSONL file, or broad unified logs into model context. `fingerprints.json` and `source-manifest.json` are machine state and are never agent inputs. `compact-events.jsonl` is a query index; inspect only selected rows.

## Progressive disclosure

1. Use the bounded brief to identify a category, event name, timestamp, or semantic fingerprint.
2. Use the source/line references in `compact-events.jsonl` to read a small causal window.
3. Reuse the same excerpt by path/fingerprint rather than pasting it again on later turns.
4. Escalate to wider raw evidence only after stating why the compact artifacts are insufficient.

Valid escalation reasons include low parse coverage, a novel unknown failure, lost causal ordering, a crash needing machine-wide state, or suspected parser/redaction loss. A high-volume event storm remains evidence: aggregate its count/rate; do not silently discard it.

## Agent routing

Deterministic preprocessing is always Tier 0. If delegation is available, a fast/low-cost agent may classify only the brief, novelty sample, and bounded excerpts. The primary reasoning agent receives that compact report. Never send raw multi-megabyte logs to another model merely because it is cheaper.

## Privacy and fidelity

Raw evidence remains unchanged and local. Generated default artifacts contain event counts, fingerprints, and source references rather than diagnostic field values. Treat raw windows as potentially sensitive and never copy them into public issues without review.
