# Jellyfin terminal cleanup: bounded investigation

## Scope

Follow-up to #323 / PR #327 and the HEVC Rext 4:4:4 startup investigation #324.
The initial local integration candidate combined PRs #327, #328 and #329 at
`0bbbbf858c2d`. One repeat used #327 head `f1a6a5e01219` plus stop-result
diagnostics only; playback and cleanup behavior were unchanged. The privacy/docs
branches were not part of that repeat. Private build provenance records the source
diff and matching clean-built/staged executable hashes.

This is native macOS DEBUG evidence, not physical-platform acceptance or a playback
success. Each attempt was explicitly authorized at 8 Mbps, serialized and bounded.
Raw server logs, commands, identifiers and media evidence remain private.

## Findings

- The initial failed startup surfaced `LS-PB-003`; no decoded frames were produced.
  Server logs showed a stop command for the current output, then a replacement encoder
  for the same output approximately five milliseconds later. The old encoder exited;
  the replacement survived app exit and the worker-absence checks.
- In the single instrumented repeat, the client recorded a stop request and successful
  acknowledgement for the same hashed play-session identity. The server again stopped
  the old job and created a replacement about five milliseconds later. The old job
  exited before the stop acknowledgement completed. Playback-stopped reporting was
  also observed separately; it is not equivalent to active-encoding cleanup.
- The repeat again surfaced `LS-PB-003`, produced no fresh frames and failed the
  post-stop worker-absence check. The sweep stopped automatically. The sole remaining
  test worker was source-verified and explicitly terminated; absence was then verified.
  Manual termination is **not** a client cleanup pass.

The observed stop was not simply omitted or lost: it reached the server and stopped
an encoder for the tested output. The evidence supports a server-side late-request/job
replacement race. It does not identify the precise queued GET or certify every possible
request ordering. No client-issued playback reopen was recorded in the repeat.

## Server implementation boundary

The deployed image was Jellyfin 10.11.11. Inspection of that exact release's
[TranscodeManager](https://github.com/jellyfin/jellyfin/blob/v10.11.11/MediaBrowser.MediaEncoding/Transcoding/TranscodeManager.cs)
shows stop selecting a snapshot of matching active jobs before awaiting termination.
Its [dynamic HLS controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/DynamicHlsController.cs)
uses an internally managed cancellation source and can start a replacement job while
servicing an already accepted segment request. A completed stop request therefore does
not establish that no later job can be created for the session. This source inspection
supports, but does not replace, the runtime correlation above.

## Client disposition and remaining gates

No new production playback workaround, sleep-based repeated stop, indefinite retry,
server tuning, service restart or library modification was introduced. The client still
detaches its player item and issues the captured session's bounded best-effort stop.
The added diagnostics expose request acknowledgement without raw endpoints or session IDs.
Existing teardown/identity tests remain the client contract; a fabricated local test of
server internals would not prove this race fixed.

#324 remains open for failed format delivery; server hardware/software codec behavior
is outside the client fix. #323 / PR #327 must retain the explicit limitation that
successful cleanup requests do not guarantee server worker exit. The bounded repeat
was executed, but worker-free automatic cleanup was **not** achieved. The broader codec
sweep remains paused; no merge or release acceptance is implied.
