# 15 — Apple Vision Pro DeviceProfile: Direct Play for in-cap content (RESEARCH / PROPOSAL ONLY)

> **Update (2026-06): partially shipped.** The decision-only probe slice
> (`directPlayProbeDecisionURL()` + `visionOSDirectPlayProbe`) landed in PMSKit with
> unit coverage; the app-side half (loading direct-play instead of `start.m3u8`) is
> deferred and tracked as [GitHub issue #7](https://github.com/jlipworth/VisionPlex/issues/7).
> (File renamed from `13-device-profile.md` — the number collided with
> `13-playback-state-apis.md`.)
>
> **Status: design doc only. No Swift source is changed by this task.** The live
> transcode/playback path is untouched. This document proposes how we *could*
> let PMS Direct Play / Direct Stream content that is already inside the user's
> bitrate cap, instead of always transcoding, and gives a reversible, step-by-step
> rollout the user can validate in the headset.
>
> Cross-refs: `research/09-transcode-api-deep-dive.md` (the wire format and
> decision vocabulary this builds on), `research/10-apple-media-api-inventory.md`
> (AVFoundation surface). Source of truth in code:
> `PMSKit/Sources/PMSKit/Transcode/TranscodeRequest.swift`,
> `PMSKit/Sources/PMSKit/Transcode/DeviceProfile.swift`,
> `PMSKit/Sources/PMSKit/Transcode/DecisionResponse.swift`,
> `PlexAVPApp/Player/PlaybackController.swift`.

---

## 0. Executive summary

- **Can we Direct Play in-cap, AVP-supported content?** Yes, in principle — and
  the architecture already does the right preparatory work: it calls the
  `/decision` endpoint before `/start.m3u8`, and it already advertises a
  capability string via `X-Plex-Client-Profile-Extra`. What's missing is (a) a
  `add-direct-play-profile(...)` directive that tells PMS *"this exact
  container+codec combo is playable as-is"*, and (b) flipping the request from
  the current unconditional `directPlay=0` to allow direct play when the source
  is in-cap. Today the request **hard-codes `directPlay=0` + `directStream=1`**,
  so PMS is *told never to direct play* regardless of whether the file would
  play natively. (`TranscodeRequest.sharedQueryItems()`.)

- **What is the single safest first change to try?** A **decision-only probe**
  that does **not** touch the production playback path. Build a *separate*
  decision request that (1) keeps `X-Plex-Client-Profile-Name=Safari` unchanged,
  (2) adds `add-direct-play-profile(...)` directives onto the existing
  `-Extra` string, and (3) sets `directPlay=1`. Send it to `/decision` only,
  log the returned `generalDecisionCode` / per-stream decisions, and **still play
  via the existing transcode `start.m3u8`**. This tells us — with zero playback
  risk — whether PMS *would* grant direct play for real library items, before we
  ever change what the player loads. (Steps in §4.)

- **The one thing we must never do again:** change
  `X-Plex-Client-Profile-Name` to an unknown value (e.g. `"visionOS"`). PMS
  resolves that name to a built-in profile file on disk; an unknown name makes
  the universal transcoder return a **bare HTTP 400** and playback dies with no
  useful body. This is already documented inline in `TranscodeRequest.swift`
  (lines ~80-85) and asserted by `TranscodeRequestTests.startURLCarriesProfileNameAndExtra`.
  The proposal below **keeps the profile name = `Safari`** and only layers
  capability deltas, exactly as `plex-for-kodi` does (research/09 §2.3).

---

## 1. What AVP / AVPlayer can actually Direct Play on visionOS 26

"Direct Play" here means: PMS serves the original file bytes (or a cheap
container remux = "Direct Stream") and **`AVPlayer` decodes them natively** with
no server-side video re-encode. So the question is really *"what can
`AVPlayer` / VideoToolbox decode on Apple Vision Pro, in a container Plex can
deliver over HLS?"*

### 1.1 Codec / container / HDR / audio support matrix

| Dimension | Native on AVP (visionOS 26) | Notes / caveats | Confidence |
|---|---|---|---|
| **H.264 (AVC)** | Yes, hardware decode, up to High/4.2+ | Safest universal video path. Plays in both MPEG-TS and fMP4 HLS segments. | High — established Apple HW baseline |
| **HEVC (H.265), 8-bit & 10-bit** | Yes, hardware decode | **Over HLS, HEVC must be in the fMP4 / CMAF container, not MPEG-TS.** Putting HEVC in MPEG-TS is the documented "buffers forever" ATV/AVPlayer bug (research/09 §5). The app's transcode-target already declares `container=mp4` for HEVC for exactly this reason (`DeviceProfile.visionOS`). | High |
| **AV1** | **Treat as NOT directly playable; verify in headset.** No dedicated AV1 hardware decode block on the M2/R1-class silicon historically; software decode is not something to rely on for a player. Safer to let PMS transcode AV1 → HEVC/H.264. | Do **not** add AV1 to a direct-play profile until empirically confirmed on the actual device. | Medium — verify |
| **Max resolution** | 4K (and AVP can present higher canvases), but **for Direct Play it is gated by our bitrate cap, not resolution.** | We do not need a resolution limitation if a bitrate limitation already keeps us in-cap; but a resolution `add-limitation` is the conventional belt-and-suspenders (research/09 §2.3). | High |
| **HDR10 / HLG** | Yes (static-metadata HDR) | Carried via the HEVC stream; AVPlayer + the cinema environment render it. Container still fMP4 for HEVC. | Medium-High — verify the cinema env honors HDR |
| **Dolby Vision** | **Verify.** AVP supports DV in the system video pipeline, but DV-over-HLS-via-Plex direct play is the riskiest HDR path (profile/RPU handling). Default to transcode until tested. | Do not whitelist DV for direct play in step 1. | Medium — verify |
| **AAC audio** | Yes | Universal; the existing transcode targets already list `aac`. | High |
| **AC-3 (Dolby Digital)** | Decode: yes. | Already listed as an audio codec in the transcode targets. For *direct play* of a file with AC-3, declare it in the direct-play profile's `audioCodec`. | High |
| **E-AC-3 / EAC3 (DD+)** | Decode: generally yes on Apple silicon | Verify the specific AVP build decodes EAC3 from a remuxed fMP4 before whitelisting. | Medium — verify |
| **TrueHD / DTS / DTS-HD** | **Treat as needing audio transcode/downmix; do NOT passthrough.** AVP has no S/PDIF bitstream-out; there is no lossless passthrough target. Let PMS transcode/copy audio to AAC or AC-3/EAC3. | Whitelisting DTS/TrueHD for direct play risks silent audio. | Medium-High |
| **Dolby Atmos (as EAC3-JOC)** | Spatial render: yes on AVP. | This is a *render* capability, not a passthrough one. For direct play we still only get what AVPlayer can decode from the remuxed stream. Treat conservatively. | Medium — verify |

**The practical takeaway for a *first* direct-play whitelist (lowest risk):**

> Whitelist only **H.264 or HEVC video in an `mp4` container with `aac` or `ac3`
> audio**, capped to the user's bitrate. That is the intersection of "AVPlayer
> definitely decodes it" and "Plex can deliver it." Everything else (AV1, DV,
> TrueHD/DTS, EAC3 multichannel) stays on the transcode path until individually
> verified on-device.

> **Why `mp4`, not the original `mkv`/`matroska`?** Most Plex libraries are MKV.
> AVPlayer / HLS does **not** ingest Matroska. So "direct play" of an MKV is
> really **Direct Stream** = a container *remux* MKV→fMP4 with **codec copy** (no
> re-encode). That is the realistic win here: the heavy CPU cost is the *video
> re-encode*, and a remux avoids it. We therefore care more about getting
> `video_decision = copy` than the literal `1000`/Direct Play code.

### 1.2 Citations / basis

- HEVC-over-HLS requires fMP4, not MPEG-TS: research/09 §5 (documented AVPlayer
  buffering bug) and the inline rationale in `DeviceProfile.swift`. Aligns with
  Apple's **HLS Authoring Specification** (HEVC must use fMP4 segments).
- AVFoundation playback surface (`AVPlayer`/`AVPlayerItem`/`AVURLAsset`) and the
  HLS/VOD constraints: research/10 §"Apple media API inventory."
- The remaining device-decode rows (AV1/DV/TrueHD/DTS/EAC3) are flagged **verify
  in headset** precisely because they are the rows most likely to regress
  playback if assumed.

---

## 2. How Plex decides Direct Play vs Direct Stream vs Transcode

### 2.1 The three outcomes (research/09 §2-3)

| Outcome | What PMS does | Server cost | How it's requested |
|---|---|---|---|
| **Direct Play** | Serves the original file bytes untouched. | ~none | `directPlay=1` **and** a matching `add-direct-play-profile(...)` for the source's `(container, videoCodec, audioCodec)` **and** all *required* limitations satisfied. |
| **Direct Stream** (remux) | Changes container / copies codecs (e.g. MKV→fMP4, no re-encode). | low | `directStream=1`; chosen when full direct play isn't possible but codecs are compatible. Per-stream `video_decision = copy`. |
| **Transcode** | Re-encodes video (and/or audio). | high (CPU/GPU) | Falls back here when no direct-play profile matches or a *required* `add-limitation` is violated. Targets the declared `add-transcode-target(...)`. |

### 2.2 Which params / headers drive the decision

From `TranscodeRequest.sharedQueryItems()` (current production values in **bold**):

| Param | Current value | Role in the decision |
|---|---|---|
| `directPlay` | **`0`** | `0` = *"do not direct play, ever."* This is why we never Direct Play today. Must become `1` to allow it. |
| `directStream` | **`1`** | Allow remux/codec-copy. Already on — good. |
| `maxVideoBitrate` | **cap (kbps)** | The hard ceiling. A source above it should transcode; in-cap should be eligible. |
| `videoQuality` | **`100`** | Quality hint. |
| `protocol` | **`hls`** | Delivery protocol; constrains containers/segments. |
| `X-Plex-Client-Profile-Name` | **`Safari`** | Names a **server-known baseline profile XML on disk.** PMS loads it, then applies our `-Extra` deltas. **An unknown name → HTTP 400 (see §2.3).** |
| `X-Plex-Client-Profile-Extra` | **`add-transcode-target…+add-limitation…`** | The capability delta string. Today it declares only *transcode targets* + a bitrate limit. It declares **no `add-direct-play-profile`**, so PMS has nothing to direct-play against even if `directPlay` were `1`. |
| `hasMDE` | **`1`** (decision only) | Asks for the Media Decision Engine result so we can read the decision before committing. |

The decision response is parsed by `DecisionResponse` →
`generalDecisionCode`: `1000` = direct play, `1001` = transcode/conversion OK,
anything else = `.unsupported`. Per-stream `video_decision` / `audio_decision` /
`container_decision` live on `<Media><Part><Stream>` (research/09 §3.2) and are
the most reliable signal of *what actually happened* (copy vs transcode).

### 2.3 Why a custom/unknown `X-Plex-Client-Profile-Name` triggers a bare HTTP 400 — DOCUMENTED SO WE NEVER REINTRODUCE IT

- `X-Plex-Client-Profile-Name` is **not** free text. PMS treats it as the name
  of a built-in profile file it loads from disk (e.g. `Profiles/Safari.xml`,
  `Chrome`, `iOS`, `Generic`). It then layers our `X-Plex-Client-Profile-Extra`
  deltas onto that baseline (research/09 §1, §2.1).
- There is **no `visionOS` profile** shipped with PMS. Passing an unknown name
  means PMS fails to resolve the baseline profile and the **universal transcoder
  returns a bare `HTTP 400`** — no JSON body, no decision, playback simply fails.
  This was **verified against live PMS** and is recorded inline in
  `TranscodeRequest.swift` (the comment above the `X-Plex-Client-Profile-Name`
  query item, lines ~80-85) and locked by
  `TranscodeRequestTests.startURLCarriesProfileNameAndExtra` (`#expect(v("X-Plex-Client-Profile-Name") == "Safari")`).
- **Rule for all future work:** the profile *name* stays a server-known value
  (`Safari`). All AVP-specific capability is expressed only through
  `X-Plex-Client-Profile-Extra` deltas (`add-direct-play-profile`,
  `add-transcode-target`, `add-limitation`). This is exactly the `plex-for-kodi`
  pattern: *baseline name + deltas* (research/09 §2.3 callout).

---

## 3. Concrete, SAFE proposal

The proposal is layered so each layer is independently testable and reversible.
Nothing here requires changing the profile *name*.

### 3.1 The capability deltas to add to `X-Plex-Client-Profile-Extra`

Keep the existing transcode targets + bitrate limitation **exactly as they are**,
and **prepend** direct-play profiles for the safe codec/container/audio set from
§1.1. Raw (pre-URL-encoding; `+`-joined per the grammar in research/09 §2.2):

```
add-direct-play-profile(type=videoProfile&container=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3)
+add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3)
+add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=ts&videoCodec=h264&audioCodec=aac,ac3)
+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=<MAX_KBPS>&isRequired=true)
```

Notes:
- The bitrate `add-limitation` with **`isRequired=true`** is what makes
  *above-cap* sources fall to transcode while *in-cap* sources stay eligible for
  direct play / remux. (Today the limitation has no `isRequired`, so it behaves
  as an advisory bound feeding the transcode target — fine for the
  transcode-only world, but for direct-play gating we want it required so an
  oversized file is forced to transcode rather than direct-played above the cap.)
- We deliberately **omit** AV1, DV, TrueHD, DTS, EAC3 from the direct-play
  profile. Those have no `add-direct-play-profile` entry → no match → they
  transcode, which is the safe behavior until each is verified on-device (§1.1).
- `container=mp4` (fMP4) is the only direct-stream container we whitelist, since
  that is what AVPlayer ingests over HLS. An MKV source therefore Direct
  *Streams* (remux→fMP4, codec copy) rather than literally byte-for-byte Direct
  Plays — which is the realistic, CPU-saving win.

### 3.2 The request-param change (only when we move past probing)

In the *playback* request (NOT in step 1 — see §4), the change is:

- `directPlay`: `0` → **`1`** (allow direct play).
- `directStream`: stays `1`.
- `maxVideoBitrate`, `videoQuality`, `protocol=hls`, profile name `Safari`: **unchanged.**

### 3.3 Expected PMS decision responses

| Source | Expected `generalDecisionCode` | Expected per-stream | Player loads |
|---|---|---|---|
| H.264/AAC mp4, in-cap | `1000` (direct play) | all `direct play`/`copy` | original/remuxed HLS, no video transcode |
| HEVC 8/10-bit + AAC/AC3 in MKV, in-cap | `1000` or `1001` with `video_decision=copy` | `container_decision=transcode` (remux), `video_decision=copy` | remuxed fMP4 HLS, **no video re-encode** |
| Any source **above cap** | `1001` | `video_decision=transcode` | transcoded HLS (today's behavior — unchanged) |
| AV1 / DV / TrueHD / DTS source | `1001` | `video_decision`/`audio_decision=transcode` | transcoded HLS (safe fallback) |

The key validation signal is the **per-stream `video_decision`**: `copy`/`direct
play` = we saved the re-encode; `transcode` = unchanged from today.

### 3.4 How this lands in code (when approved — NOT in this task)

- `DeviceProfile.visionOS(...)` gains the `add-direct-play-profile(...)` directive
  and an `isRequired=true` on the bitrate limitation. **Additive** to the
  `-Extra` string; the existing transcode targets stay so above-cap content still
  has a valid target.
- A new, *optional* code path in `PlaybackController.startStreaming` chooses
  `directPlay=1` based on the `/decision` result, and only falls back to the
  current `directPlay=0` transcode request on a non-direct-play decision. The
  `Decision` enum + `DecisionResponse` already exist to drive this branch.
- Because `start.m3u8` is still the delivery URL in all cases, the player,
  subtitle, resume, timeline, and download paths are untouched.

---

## 4. Step-by-step rollout / test plan (each step independently reversible)

> Principle: **observe before you switch.** We learn what PMS *would* decide
> before we change what the player loads. Steps 1-2 cannot regress playback at
> all because they don't alter the URL the player opens.

**Step 0 — Baseline (no code change).** In the headset, play a known MKV/HEVC
title and a known H.264 mp4 title on the current build. Open Stats-for-Nerds and
record: decision code shown, whether video is transcoding, bitrate. This is the
control. (Reversible: nothing changed.)

**Step 1 — Decision-only probe (no playback change).** Add a *parallel* decision
call that builds a second `-Extra` string (with the `add-direct-play-profile`
deltas from §3.1) and `directPlay=1`, sends it to `/decision` only, and **logs**
the `generalDecisionCode` + per-stream decisions. The player still loads the
existing `directPlay=0` transcode `start.m3u8`. Verify in the headset that
in-cap H.264/HEVC titles report `1000`/`copy` in the log while playback is
visually identical to Step 0. (Reversible: delete the probe; production path was
never touched.)

**Step 2 — Profile-string review.** Confirm the probe's `-Extra` URL-encodes
correctly and PMS does **not** 400 (it won't — profile name is still `Safari`).
Confirm above-cap titles still log `1001`/`transcode` (the `isRequired=true`
bitrate limit is doing its job). (Reversible: same as Step 1.)

**Step 3 — Enable direct play behind a flag, for the safe codec set only.** Flip
the *playback* request to use `directPlay=1` + the new profile **only** when the
Step-1 decision returned direct-play/copy; otherwise fall back to today's exact
transcode request. Gate it behind a Settings toggle (default OFF) so the user
can disable it instantly in-headset if anything looks wrong. Test the H.264 mp4
title first (lowest risk), confirm it plays with no transcode and that seek /
resume / subtitles / timeline still work. (Reversible: toggle OFF → identical to
today.)

**Step 4 — Add HEVC/MKV remux.** With the toggle on, play the HEVC-in-MKV title.
Confirm `video_decision=copy`, smooth playback (watch specifically for the
HEVC-in-TS "buffers forever" symptom — must be fMP4), audio present, HDR looks
right in the cinema environment. (Reversible: toggle OFF.)

**Step 5 — Edge audio/HDR probes (optional, one at a time).** Only after 3-4 are
solid, *individually* test adding EAC3 audio, then HDR10, then (last) consider
DV — each as its own reversible change with its own headset check. Stop at the
first one that misbehaves and leave it on the transcode path.

**Step 6 — Soak.** Leave the toggle on for a few real viewing sessions across
movie + episode content, watching for mid-stream stalls, audio dropouts, or
resume/seek regressions before considering default-ON.

---

## 5. Risks and specific regressions to watch

1. **HTTP 400 from an unknown profile name.** *Mitigated by design:* we never
   change the name from `Safari`. If a future edit ever sets it to anything else,
   expect an immediate bare 400 and dead playback. The test
   `startURLCarriesProfileNameAndExtra` guards this.
2. **HEVC delivered in MPEG-TS instead of fMP4 → infinite buffering.** If a
   direct-stream/remux path hands HEVC in a `ts` container, AVPlayer buffers
   forever (research/09 §5). *Mitigation:* only whitelist HEVC with
   `container=mp4`; never list HEVC on a `ts` transcode target. Watch Step 4 for
   the spinner-that-never-clears symptom (`buffering` state stuck on).
3. **Silent / broken audio from unsupported passthrough.** If we ever whitelist
   TrueHD/DTS for direct play, AVP can't bitstream them out → no audio.
   *Mitigation:* keep those off the direct-play profile; let PMS transcode audio.
4. **HDR/DV color regressions.** Direct-playing DV/HDR that the cinema
   environment doesn't tone-map correctly → washed-out or too-dark image.
   *Mitigation:* DV stays on transcode until explicitly verified (Step 5, last).
5. **Above-cap content sneaking through as direct play.** If the bitrate
   `add-limitation` is *not* `isRequired=true`, PMS may direct-play a file above
   the user's cap, blowing the bandwidth budget on a remote connection.
   *Mitigation:* the limitation must be `isRequired=true` (§3.1); verify in
   Step 2 that an above-cap title still transcodes.
6. **Resume / `#EXT-X-START` priming behaves differently on a remux vs a
   transcode.** The current resume logic primes the transcoder via the `offset`
   param and has a client-side seek fallback (`PlaybackController` §"Streaming
   path"). A direct-streamed/remuxed asset may handle the offset differently.
   *Mitigation:* explicitly test resume on a direct-played title in Steps 3-4; the
   existing client-side seek fallback should still land the playhead, but confirm.
7. **Subtitle behavior.** Today subs ride as soft HLS renditions
   (`subtitles=auto`) muxed by PMS during transcode. On a pure direct play, the
   server may not mux a legible group the same way. *Mitigation:* check the
   subtitle picker still populates in Step 3-4; if image subs (PGS/VOBSUB) are
   present they still force burn-in (which forces a video transcode anyway, so
   those titles simply won't direct play — acceptable).
8. **Decision/start divergence.** `decisionAndStartShareTheSameCoreParams`
   currently asserts the decision and start URLs share core params. Any
   direct-play branch must keep decision and the chosen start request consistent,
   or PMS may make a decision that doesn't match what the player then requests.
   *Mitigation:* build one param set per branch and reuse it for both
   decision + start, exactly as `TranscodeRequest` does today.

---

## 6. Verification of "no behavior change" for this task

- The **only** file created by this task is this document,
  `research/15-device-profile.md`. No Swift source was modified; `git status`
  shows only `research/15-device-profile.md`.
- No build is required (no code changed). The existing
  `TranscodeRequestTests` continue to pin the production contract
  (`directPlay=0`, `X-Plex-Client-Profile-Name=Safari`), which this task does not
  alter.
