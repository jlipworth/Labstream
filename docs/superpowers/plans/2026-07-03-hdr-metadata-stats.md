# HDR Metadata & Stats Reporting (GH #195) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface source HDR format (HDR10 / HDR10+ / HLG / Dolby Vision profile+fallback), color detail, and runtime AVFoundation HDR state in the Stats for Nerds panel and diagnostics export, across Plex, Jellyfin, and Emby.

**Architecture:** A backend-neutral `VideoHDRMetadata` value type lives in PMSKit and is derived from (a) new Plex `Stream` HDR/DV fields, (b) new MediaBrowser (Jellyfin/Emby) `MediaStream` HDR fields. It flows to the app through `Part.streams` (Plex) and `MediaBrowserPlaybackSourceMetadata.hdr` (JF/Emby). The app adds an AVFoundation runtime probe (`containsHDRVideo`, transfer function, `eligibleForHDRPlayback`) run at `.readyToPlay`, and renders "Source HDR" / "Runtime HDR" rows in `StatsForNerdsView` plus diagnostics-export fields.

**Tech Stack:** Swift 6, swift-testing (PMSKit tests), AVFoundation/CoreMedia (app probe).

## Global Constraints

- Direct-play policy stays conservative — do NOT touch `PMSKit/Sources/PMSKit/Transcode/DeviceProfile.swift` (issue #195 follow-up 6).
- Never log/display URLs, tokens, media titles, item IDs, playSession IDs (repo rule + issue follow-up 7).
- Do NOT claim AVPlayer renders HDR10+; label as "HDR10+" source format only (backend metadata), runtime shows PQ base layer facts.
- Plex profile name stays `Generic` (hard constraint — untouched).
- All decoding is lenient: every new field optional; unknown enum strings degrade to `nil`/`unknownHDR`, never throw.
- New Swift files are picked up automatically; never edit pbxproj.

---

### Task 1: `VideoHDRMetadata` model + classification (PMSKit)

**Files:**
- Create: `PMSKit/Sources/PMSKit/Models/VideoHDRMetadata.swift`
- Test: `PMSKit/Tests/PMSKitTests/VideoHDRMetadataTests.swift`

**Interfaces (Produces):**
```swift
public enum VideoHDRFormat: String, Sendable, Equatable, CaseIterable {
    case sdr, hdr10, hdr10Plus, hlg, dolbyVision, unknownHDR
}
public struct VideoDolbyVisionInfo: Sendable, Equatable {
    public let profile: Int?; public let level: Int?
    public let blCompatibilityID: Int?   // 0=none(P5-style), 1=HDR10, 2=SDR, 4=HLG, 6=HDR10(UHD-BD)
    public let rpuPresent: Bool?; public let elPresent: Bool?; public let blPresent: Bool?
}
public struct VideoHDRMetadata: Sendable, Equatable {
    public let format: VideoHDRFormat
    public let bitDepth: Int?
    public let colorPrimaries: String?; public let colorTransfer: String?
    public let colorSpace: String?; public let colorRange: String?
    public let dolbyVision: VideoDolbyVisionInfo?
    public let hdr10PlusPresent: Bool?
    public var displayLabel: String { … }   // "Dolby Vision P8.1 (HDR10 fallback)", "HDR10 PQ · BT.2020 · 10-bit", "HLG", "HDR10+", "SDR"
    public var shortLabel: String { … }     // "DV P8", "HDR10", "HDR10+", "HLG", "SDR"
}
```

Classification precedence (shared static helper used by Tasks 2–3):
1. DV present (`doviPresent == true` or dvProfile != nil) → `.dolbyVision` (+ fallback name from blCompatibilityID: 1/6→"HDR10 fallback", 2→"SDR fallback", 4→"HLG fallback", 0/nil with profile 5→"no fallback").
2. HDR10+ flag → `.hdr10Plus`.
3. transfer ∈ {"smpte2084","pq","smpte st 2084"} (case-insensitive) → `.hdr10`.
4. transfer ∈ {"arib-std-b67","hlg"} → `.hlg`.
5. explicit backend range string says HDR but nothing above matched → `.unknownHDR`.
6. transfer known-SDR ("bt709","bt601", "smpte170m", …) OR bitDepth==8 with no HDR signals → `.sdr`.
7. Nothing known → classification returns `nil` (caller shows no row).

Steps: write failing tests for the matrix above (DV8.1/HDR10-fallback, DV5/no-fallback, HDR10 via smpte2084, HLG, HDR10+, SDR bt709, empty→nil, label formatting) → run (`cd PMSKit && swift test --filter VideoHDRMetadata`) → implement → pass → commit.

### Task 2: Plex `Stream` HDR/DV decode

**Files:**
- Modify: `PMSKit/Sources/PMSKit/Models/Library.swift` (`Stream`, ~line 723)
- Test: `PMSKit/Tests/PMSKitTests/PlexStreamHDRDecodeTests.swift`

Add optional fields + CodingKeys: `bitDepth`, `colorPrimaries`, `colorRange`, `colorSpace`, `colorTrc`, `DOVIPresent`, `DOVIProfile`, `DOVILevel`, `DOVIBLCompatID`, `DOVIBLPresent`, `DOVIELPresent`, `DOVIRPUPresent`. Plex emits booleans as JSON `true` or `1` depending on endpoint — decode leniently (Bool, then Int != 0, then String "1"/"true"). Reuse an existing lenient-bool helper if one exists in PMSKit; otherwise add a private `decodeLenientBool` in the file.

Expose `public var hdrMetadata: VideoHDRMetadata?` (video streams only) calling the Task 1 classifier.

Fixture: sanitized JSON stream objects (DV MKV, HDR10, SDR) with NO real hostnames/titles/ids. Tests: decode each fixture, assert fields + `hdrMetadata` classification; assert old fixtures (no HDR keys) still decode with nils.

### Task 3: MediaBrowser (Jellyfin/Emby) HDR decode + carrier

**Files:**
- Modify: `PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserItemModels.swift` (`MediaBrowserItemMediaStreamDto`, ~line 484)
- Modify: `PMSKit/Sources/PMSKit/Jellyfin/JellyfinPlayback.swift` (`JellyfinPlaybackSourceMetadata`, `playbackSourceMetadata(audioStreamIndex:)` ~line 141)
- Modify: `PMSKit/Sources/PMSKit/Emby/EmbyPlayback.swift` (same pattern, ~line 185)
- Modify: `PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserPlaybackCarriers.swift` (`MediaBrowserPlaybackSourceMetadata`, ~line 30)
- Test: `PMSKit/Tests/PMSKitTests/MediaBrowserHDRDecodeTests.swift`

DTO gains: `videoRange` ("SDR"/"HDR"), `videoRangeType` (JF: "HDR10","HLG","DOVI","DOVIWithHDR10","DOVIWithHLG","DOVIWithSDR","HDR10Plus",…), `videoDoViTitle`, `bitDepth`, `colorRange`, `colorSpace`, `colorTransfer`, `colorPrimaries`, `dvProfile`, `dvLevel`, `dvBlSignalCompatibilityId`, `rpuPresentFlag`, `elPresentFlag`, `blPresentFlag`, `hdr10PlusPresentFlag`, Emby `extendedVideoType`, `extendedVideoSubType` — all optional, CodingKeys in PascalCase per existing style. Expose `public var hdrMetadata: VideoHDRMetadata?` mapping `videoRangeType`/`extendedVideoType` into the Task 1 classifier (DOVIWith* → DV + fallback; Emby "Hdr10"/"Hdr10Plus"/"DolbyVision"/"Hlg" case-insensitive).

`JellyfinPlaybackSourceMetadata`/`EmbyPlaybackSourceMetadata`/`MediaBrowserPlaybackSourceMetadata` gain `public let hdr: VideoHDRMetadata?` (default nil to keep existing inits/tests source-compatible), populated in `playbackSourceMetadata(audioStreamIndex:)` from the selected video stream.

Fixtures: JF DOVIWithHDR10 sample, JF HDR10 via VideoRangeType, JF HDR10Plus, Emby ExtendedVideoType Hdr10Plus, legacy no-HDR JSON. Tests assert decode + classification + carrier propagation through the two bridge inits in `MediaBrowserPlaybackCarriers.swift`.

### Task 3.5: Friendly AV format labels (PMSKit)

User request (2026-07-03): Stats must show native AV info — DoVi/HDR for video and
friendly audio format names (AC3 → Dolby Digital, EAC3 → Dolby Digital Plus, DTS/DTS-HD,
TrueHD, AAC, FLAC, Opus…) with channel layout (2.0/5.1/7.1).

**Files:**
- Create: `PMSKit/Sources/PMSKit/Models/AVFormatLabels.swift`
- Test: `PMSKit/Tests/PMSKitTests/AVFormatLabelsTests.swift`

**Interfaces (Produces):**
```swift
public enum AVFormatLabels {
    /// "Dolby Digital Plus (E-AC-3) 5.1", "DTS-HD MA 7.1", "AAC 2.0", raw codec fallback.
    public static func audioDisplayName(codec: String?, channels: Int?, profile: String? = nil) -> String?
    /// "HEVC 10-bit · Dolby Vision P8 (HDR10 fallback)" — codec + optional HDR short/display info.
    public static func videoDisplayName(codec: String?, hdr: VideoHDRMetadata?) -> String?
    /// "5.1", "7.1", "2.0", "Mono"
    public static func channelLayoutName(_ channels: Int?) -> String?
}
```
TDD matrix: ac3, eac3, truehd (+Atmos via profile string containing "atmos"), dts (profile "DTS-HD MA"/"DTS:X"), aac, flac, opus, mp3, unknown codec passthrough, nil → nil; channels 1/2/6/8/nil.
Plex `Stream.profile` (audio) and JF/Emby `Profile` feed the `profile` param — decode those fields in Tasks 2/3.

### Task 4: App — source HDR row plumbing + AV info rows

**Files:**
- Modify: `VisionPlay/Player/PlaybackSourceSummary.swift` (add `hdr: VideoHDRMetadata?`; populate in `.plex` from `part?.videoStreams.first?.hdrMetadata`, in `.mediaBrowser` from `source.hdr`; add `source_hdr` + `source_hdr_detail` diagnostic fields via `.label`)
- Modify: `VisionPlay/Player/PlaybackDiagnostics.swift` (`sourceHDRLabel: String?` set in `applySourceSummary`; tone-map hint: when `isTranscoding && hdr != nil && hdr.format != .sdr`, expose `outputHDRHint = "tone-mapped to SDR (server-side, probable)"`)
- Modify: `VisionPlay/Player/StatsForNerdsView.swift` (conditional rows `Source HDR`, `Output` after the Video row; Video/Audio rows upgraded to `AVFormatLabels.videoDisplayName` / `audioDisplayName` with raw-codec fallback)
- `PlaybackSourceSummary` gains `audioProfile: String?` and `audioChannels` already exists — feed both into `AVFormatLabels.audioDisplayName`.

Build check: full simulator build must compile (no PMSKit test cycle here; app has no unit target for these files — verification is Task 6 smoke test).

### Task 5: App — AVFoundation runtime HDR probe

**Files:**
- Create: `VisionPlay/Player/PlaybackHDRProbe.swift`
- Modify: `VisionPlay/Player/PlaybackDiagnostics.swift` (add `runtimeHDRLabel: String?`)
- Modify: `VisionPlay/Player/PlaybackController.swift` (`installObservers` `.readyToPlay` branch ~line 2670: fire probe Task, store result into diagnostics; guard per-item once)
- Modify: `VisionPlay/Player/StatsForNerdsView.swift` (row `Runtime HDR`)
- Modify: `VisionPlay/Player/PlaybackController+Diagnostics.swift` (export `runtime_hdr` field)

Probe (async, main-actor hop only for the write-back):
```swift
struct PlaybackHDRProbeResult: Equatable {
    var containsHDRVideo: Bool
    var transferFunction: String?     // "PQ" / "HLG" / raw CV constant suffix
    var eligibleForHDRPlayback: Bool
    var label: String { … }           // "HDR · PQ · eligible" / "SDR · eligible"
}
```
Implementation: `try? await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)` (non-empty → HDR); first video track `formatDescriptions` → `CMFormatDescription.Extensions` transfer function (`kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ` → "PQ", `_ITU_R_2100_HLG` → "HLG"); `AVPlayer.eligibleForHDRPlayback`. Never log asset URLs. HLS note: format descriptions may be empty until segments load — probe is best-effort, re-run once on first diagnostics sample if empty (cheap guard flag).

### Task 6: Build, smoke test, docs

- Full clean-product simulator build on this worktree's `$SIMID`, install, launch, log scan, screenshot (CLAUDE.md smoke ritual; Stats panel visually checked during Plex playback if reachable).
- `cd PMSKit && swift test` — full suite green.
- Update `TESTING-CHECKLIST.md` with the #195 manual validation matrix (SDR / HDR10 / HLG / DV8.x / DV5 / HDR10+ rows, per backend, direct vs transcode) — condensed from the issue comment.
- Update `docs/DEVELOPMENT.md` with the verified platform findings (eligibleForHDRPlayback, no HDR10+ AVPlayer mode bit, deprecated availableHDRModes).
- Commit sequence per task; final commit references #195.
