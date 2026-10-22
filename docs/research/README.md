# Active research

This lane is only for unresolved investigations that may shape future implementation. A research note should make the open questions, competing interpretations, source evidence, and validation needed for a decision explicit.

## What belongs here

- investigations whose answer or implementation direction is still unknown;
- source/API comparisons that need live or device validation before becoming an accepted invariant;
- bounded spikes with an explicit decision or validation exit.

Do not put approved implementation plans here (`docs/plans/`), immutable audit or profiling evidence here (`docs/evidence/`), resolved reviews or closed investigations here (`docs/archive/`), or current product guidance here (the published top level of `docs/`).

## Naming and lifecycle

Name new notes `YYYY-MM-DD-<topic>.md`. Topic-named notes created before this rule was enforced keep their names until archived. State the unresolved questions and exit criteria near the top, cite primary sources, and avoid presenting hypotheses as shipped behavior.

When the investigation resolves:

- move approved implementation work to `docs/plans/`;
- move durable observations to `docs/evidence/` when they remain useful as comparison data;
- promote proven behavior into the relevant current published pages; and
- move a closed investigation to `docs/archive/research/` when its historical reasoning is still worth retaining.

## Active research notes

- [`2026-10-22-download-backlog-memory-and-writes.md`](2026-10-22-download-backlog-memory-and-writes.md)
  — bounded synthetic investigation of side-asset payload queues, inherited file
  backlog, and static append write amplification (#394, #390, #391).

- [`dv-p7-decoder-boundary.md`](dv-p7-decoder-boundary.md) — bounded cross-backend DV/HDR
  delivery investigation and exact-source decoder experiments. The macOS P7 HDR10-base
  candidate is default-off and DEBUG-only; full-session and physical acceptance remain open.
- [`emby-av1-startup.md`](emby-av1-startup.md) — records the bounded Emby AV1 cold-start
  mitigation from [issue #305](https://github.com/jlipworth/Labstream/issues/305). The
  server-wide and physical-device/release acceptance gates remain open; this is not a
  universal AV1 playback claim.
- [`native-hdr-validation.md`](native-hdr-validation.md) — tracks bounded HDR/Dolby Vision
  source, decode, display-capability, and cross-backend validation. The Plex P7 decoder
  issue [#316](https://github.com/jlipworth/Labstream/issues/316) is closed; physical
  display/device and equivalent Jellyfin/Emby acceptance remain open.

The Emby HEVC 10-bit SDR and overlapping-session reopen records moved to
[`docs/evidence/audits/`](../evidence/audits/) after their fixes shipped; the tvOS screen audit
is now an active plan in [`docs/plans/`](../plans/).
