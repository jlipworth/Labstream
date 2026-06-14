# VisionPlex player reset: final-target rebuild, no retry storms

Date: 2026-06-14
Status: approved direction, pending implementation plan
Scope: replace the failed Stage-3 proxy-owned segment seek design with a simpler, server-safe player model.

## Background

The Stage-3 proxy experiment tried to make deep scrub seeks seamless by keeping one stable AVKit HLS item while the loopback proxy intercepted stub `.ts` segments, re-primed PMS at the segment's absolute time, and returned current-session media under the old playlist.

Manual testing disproved the design. A single deep backward drag could work, but double-drag and rapid scrub paths repeatedly produced AVKit retry loops, local HTTP failures, 502s, upstream timeouts, and likely PMS transcode pressure. Patches for handler cancellation and short client-stability gating reduced specific failure classes but did not eliminate the architectural failure shape.

The new constraint is explicit: VisionPlex must not amplify a scrub into retry/restart hell, repeated 503s, or multiple PMS transcodes for the same user intent. Reliability and server safety outrank seamless native scrubbing.

## Design goal

Use a visible but reliable final-target reload model:

- AVKit remains the renderer and owns normal playback UI.
- VisionPlex acts only on the user's final seek target, not every intermediate segment request.
- At most one PMS re-prime/rebuild runs at a time per playback session.
- Intermediate seek targets are coalesced or ignored; the latest final target wins.
- Automatic retry loops are removed or tightly bounded.
- If a rebuild fails, VisionPlex surfaces a user-visible error with a one-shot Retry action instead of silently retrying.

## Non-goals

- No invisible segment splicing through an HLS proxy.
- No proxy-triggered PMS re-prime from `.ts` requests.
- No attempt to make every deep scrub look like a native in-buffer seek.
- No automatic retry-until-success behavior.
- No multiple concurrent `/decision`, `/start.m3u8`, or `/stop` calls for one playback session.

## Architecture

### Playback modes

1. **Normal playback**
   - The app resolves a PMS stream URL for the chosen item and offset.
   - `AVPlayerItem` is loaded from that URL.
   - Small in-buffer seeks use AVKit natively and should remain instant.

2. **Final-target deep seek rebuild**
   - When the user performs a deep/out-of-buffer scrub and playback cannot resume cleanly from the current transcode, VisionPlex rebuilds intentionally at the final target.
   - The rebuild path:
     1. record the latest target offset;
     2. cancel/drop any stale pending rebuild intent;
     3. optionally send one bounded `stop` for the previous transcode session;
     4. run one PMS decision/start flow for the final offset;
     5. create a new `AVPlayerItem` at that start URL;
     6. replace the player item once;
     7. resume playback if the user was playing.

3. **Failure state**
   - If the rebuild fails or PMS returns repeated errors, stop automatic work.
   - Surface the existing failure overlay.
   - Retry is user-triggered and one-shot. A failed Retry returns to the overlay, not another loop.

### Proxy role

The intelligent Stage-3 proxy is removed from seek recovery.

Acceptable proxy options during implementation, in order of preference:

1. **Remove proxy from the default seek path.** Use direct PMS start URLs for rebuilt player items.
2. **Keep a minimal proxy only behind a debug/experiment flag.** It may forward bytes or test socket rotation, but it must not own seek recovery or trigger PMS re-primes from segment requests.
3. **Delete the proxy if it adds risk.** Server safety and simpler behavior take precedence over preserving the abstraction.

The implementation plan should choose the smallest rollback that restores a safe direct/rebuild path first. Any future proxy work must be reintroduced behind a feature flag with explicit server-safety tests.

## State machine

The player should have one rebuild controller with these conceptual states:

- `idle`: no rebuild in progress.
- `pending(offset)`: a final target was recorded but work has not started or is waiting for a short debounce/settle point.
- `rebuilding(generation, offset)`: one stop/decision/start/item-replace pipeline is active.
- `failed(error)`: automatic work stopped; UI can offer one Retry.

Rules:

- Only one `rebuilding` pipeline may exist at a time.
- A newer final target supersedes an older pending target.
- A newer generation cancels stale work and stale completions must not replace the current item.
- Rebuild attempts are rate-limited per playback session.
- User Retry starts one new generation and then stops if it fails.

## Server-safety requirements

Implementation must prove these properties with tests or instrumentation:

1. Rapid seek inputs collapse to the final target.
2. Only one PMS start/decision flow runs for the final target.
3. Stale work cannot replace the player item after a newer generation starts.
4. Stop-before-start is bounded and best-effort; it cannot hang the rebuild behind a dead control plane.
5. Automatic retries are either absent or hard-limited to one explicit path with clear accounting.
6. Failure overlay stops background recovery work.
7. Closing the player cancels pending rebuild work and does not leave transcode/session tasks running.

## UX expectations

- Deep scrub may visibly reload or briefly show buffering at the final target.
- This is acceptable if it is deterministic, bounded, and does not hammer PMS.
- Small in-buffer scrubs should remain native and instant.
- If PMS is slow or unavailable, the user sees a clear failure instead of hidden retry churn.
- Retry is an explicit user choice.

## Testing plan outline

Detailed implementation planning should include:

- Unit tests for the rebuild controller's latest-wins behavior.
- Unit tests for generation fencing and stale completion rejection.
- Unit tests or integration seams proving one final seek does not create multiple PMS decision/start calls.
- Manual simulator/headset checklist:
  - normal playback starts;
  - small in-buffer seek is instant;
  - deep single scrub reloads at release point;
  - double-drag reloads only at final release point;
  - repeated failed PMS responses surface one overlay without retry storm;
  - closing during rebuild returns cleanly with no black screen/audio bleed.

## Rollback guidance

The existing Stage-3 segment machinery should be removed or disabled before implementing this model:

- remove segment timeline parsing from the active seek path;
- remove proxy-owned segment stub detection/re-prime behavior;
- remove client-stability gate and segment poll deadlines from production behavior;
- keep only tests/docs that remain relevant to the chosen final-target rebuild model.

Do not preserve Stage-3 code merely because it exists. The goal is a smaller, safer playback path.
