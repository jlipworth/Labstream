# Emby HEVC 10-bit SDR quality-reopen corruption

[Issue #304](https://github.com/jlipworth/Labstream/issues/304) remains open for
physical-device, dynamic-fragment/decoder analysis, and broader server-version acceptance.
[The H.264 delivery issue #291](https://github.com/jlipworth/Labstream/issues/291) is
related context, not proof of a shared cause. AV1 startup is separate (#305); HDR is excluded.

## Established boundary

An exact-item/source iPhone simulator run reproduced clean Original playback followed by
block/smear artifacts at 8 Mbps. Transport checks passed despite visibly corrupted frames.
Independent software decoding of the same source interval was clean; server commands
copied video/audio into fragmented MP4, rather than encoding video.

Removing offset priming initially produced clean frames but restarted near zero: that
control was not a fix. Adding explicit native resume preserved the target and produced
clean frames in the previously corrupted scene. This isolates the legacy offset-primed
startup/proxy path as the reproduced boundary, not the precise fragment/init or decoder
mechanism. A stored server playlist does not establish what its dynamic endpoint delivered.

## Mitigation and evidence

[Current playback policy](../PLAYBACK-ARCHITECTURE.md#emby)
keeps the negotiated session, audio and container, removes only `StartTimeTicks`, and uses
native full-timeline resume/seek for eligible HEVC 10-bit SDR copy-compatible HLS. It neither
substitutes MPEG-TS nor forces encoding. Unknown facts, transforms, HDR, other codecs/bit
depths, and sources above the ceiling retain their prior paths. A newer user seek supersedes
a delayed initial resume.

- Candidate Original-to-8-Mbps transition and repeat each had four initial and four clean
  post-transition frames with preserved progress. Source-matched server evidence retained
  HEVC copy and fragmented MP4.
- A separate 10-minute native seek at 8 Mbps passed a subsequent hold with visible frames;
  this is not a complete seek/lifecycle matrix.
- Exact HEVC 8-bit SDR and H.264 controls passed the same quality transition without
  selecting the new lane.
- Pure tests cover exclusions, unknown/duplicate reasons, ceiling limits and URL-parameter
  preservation. Fresh native builds and platform smoke checks supplement, but do not replace,
  physical-device playback acceptance.

Failed controls and raw evidence remain private. Frame counts or a moving playhead alone
never establish visual correctness.
