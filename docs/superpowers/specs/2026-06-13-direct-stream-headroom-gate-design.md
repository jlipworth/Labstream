# Direct Stream Headroom Gate (#31) Design

## Goal

Add a second experimental, default-off playback setting that makes Direct Stream more conservative on constrained links. Existing `Direct Stream (experimental)` remains the master opt-in. The new gate only changes behavior when the user explicitly enables it too.

## Behavior

Settings exposes a new `Require bandwidth headroom` toggle under Playback, disabled unless Direct Stream itself is enabled. Defaults to OFF so current Direct Stream test behavior is unchanged.

When Direct Stream is enabled and PMS confirms it can copy/direct-play video, playback applies the headroom gate only if the new toggle is ON:

1. Read source bitrate from the selected `Media.bitrate` in kbps.
2. Read a recent observed-throughput estimate persisted from `AVPlayerItemAccessLog` sampling.
3. Require observed throughput to be at least 1.25× the source bitrate.
4. If source bitrate or throughput estimate is missing, fall back to the capped transcode path.

This is intentionally conservative. It avoids committing to a single-rendition direct stream without evidence that the link can carry it. #32 remains separate and will add user-facing explanation/toasts later.

## Data flow

`PlaybackDiagnostics.sample(player:)` already reads `observedBitrate`. When it sees a positive sample, it persists the latest observed throughput in UserDefaults. `PlaybackController.startStreaming(...)` reads that value before committing `directPlayStartM3U8URL()`.

The pure gate logic lives in PMSKit so it can be unit-tested without a simulator.

## Testing

PMSKit tests cover:

- Gate disabled means no headroom check is required.
- Missing source bitrate blocks when the gate is enabled.
- Missing throughput estimate blocks when the gate is enabled.
- Throughput below 1.25× source blocks.
- Throughput at/above 1.25× source allows.
- Media source bitrate extraction honors the selected media index.

App verification covers Settings UI wiring, no default behavior change, and build/hygiene.
