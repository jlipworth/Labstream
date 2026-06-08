# plex-avp-app

A personal-use, native **visionOS (Apple Vision Pro)** Plex client whose goal is to combine, in a single app, the three things no current visionOS Plex app cleanly does together:

1. **Reliable server-side transcoding** (request a bitrate-capped HLS stream, not direct-play-only)
2. **Theater-mode playback** — a giant virtual screen in a cinema environment
3. **Offline downloads** of Plex library items (so a slow connection / large file isn't a wall, and you don't need a second app)

> Status: **research complete, no app code yet.** This repo currently holds the research that informs the design. App scaffolding is intentionally deferred until a design is agreed. See [Next steps](#next-steps).

---

## Why this project exists

The official Plex "visionOS app" is just the iPad build in compatibility mode — so it has **no theater mode**. The native third-party apps (Theater, Aurora, Chroma, Plexi) each nail *some* of the three priorities but none cleanly nails all three. The user has already validated that **their Plex server transcodes fine**, so the server is not the bottleneck — the gap is purely on the client side.

## Research (`research/`)

| # | Topic | One-line verdict |
|---|-------|------------------|
| [01](research/01-plex-api-transcoding.md) | Plex API + transcoding | PIN-OAuth → `X-Plex-Token`; force HLS via `/video/:/transcode/universal/start.m3u8?protocol=hls&maxVideoBitrate=8000&directPlay=0`. **`plexswift` is too weak (archived, DASH-only, no bitrate param) — hand-roll the streaming calls.** Downloads are easy and **need no Plex Pass** (`Part.key?download=1`). |
| [02](research/02-visionos-playback-theater.md) | visionOS playback + theater | **Theater mode is nearly free** — `AVPlayerViewController` + system Cinema Environments, no render code. **3D SBS/TAB is the only hard part** (no system support; needs custom ShaderGraph render or pre-convert to MV-HEVC). Pass the token as a **query param**, not a header. |
| [03](research/03-app-architecture-sideload.md) | Architecture + sideload | Standard SwiftUI app, 6 modules (AppState, PlexAuth, PlexAPI, Player, DownloadManager, LibraryUI). **Biggest downside: free-Apple-ID profiles expire every 7 days** → Mac-tethered rebuild. AltStore/SideStore don't support visionOS. |
| [04](research/04-competitive-teardown.md) | Competitive teardown | No single app pairs robust transcode + confirmed Plex downloads + 3D SBS. **Chroma** is closest (downloads + transcode + theater, but transcode reliability is questioned and no SBS). **Theater** has the best theater + reliable transcode but **Plex downloads unconfirmed**. |
| [05](research/05-mobile-client-ux-reference.md) | Mobile client UX reference | Mature clients converge on **Home · Libraries · Search + Detail + Player + Settings**. Swiftfin's 3-tab model is the cleanest template. MVP = single-server login, Home hubs, poster grid, detail screen, big-screen player with bitrate/transcode fallback. |
| [06](research/06-prerequisites-licensing.md) | Prerequisites + licensing | See [What to gather](#what-to-gather-prerequisites). **Transcode is free; downloads/sync via the official Mobile Sync path need Plex Pass — but the simple `download=1` fetch does not.** All OSS deps are permissive (MIT/BSD). |

### Round 2 — API deep-dive

| # | Topic | One-line verdict |
|---|-------|------------------|
| [07](research/07-plex-official-api-surface.md) | Plex official API surface | **An official OpenAPI spec now exists** (developer.plex.tv/pms/, since Sep 2025, needs PMS ≥ 1.43.2) and **covers the Transcoder** — better than `plexswift`. Still no official Swift SDK → hand-roll networking. `X-Plex-Token` still works; **JWT migration is medium-risk, not imminent** (PMS still rejects JWTs) — abstract the token layer. |
| [08](research/08-plex-client-library-catalog.md) | Client library catalog | Best transcode references: **`plex-for-kodi`** (Plex's own client code — highest fidelity, but **GPL-2.0 → re-implement, don't copy**) and **`python-plexapi` `getStreamURL()`** (**BSD-3, safe to port**). Every LukeHagar SDK shares the same weak generated transcode ops. |
| [09](research/09-transcode-api-deep-dive.md) | Transcode API deep-dive | Full parameter matrix + the **DeviceProfile capability system** (`X-Plex-Client-Profile-Extra` directives that force the right transcode decision) + **decision-response codes** (1000≈direct play / 1001≈transcode). Call `/decision?hasMDE=1` first, then `start.m3u8`. Has a worked "1080p ~8 Mbps burn-subs" URL. |
| [10](research/10-apple-media-api-inventory.md) | Apple media-API inventory | **Offline-download crux:** `AVAssetDownloadTask` is **VOD-only and won't reliably download Plex's live-style transcode HLS.** Use Plex **Media Optimizer** for a finished capped file via plain `URLSession` (see round 3 — no Plex Pass needed), OR roll your own segment downloader. Full feature→API map included. |

### Round 3 — feasibility spike + build references

| # | Topic | One-line verdict |
|---|-------|------------------|
| [11](research/11-offline-download-spike.md) | Offline-download spike | **CRUX SOLVED.** Plex **Media Optimizer creates a capped-bitrate MP4 *version* on your own server in the FREE edition** (no Plex Pass), with a built-in **"Optimized for TV – 8 Mbps 1080p"** preset = your exact target. Download it with the same free `?download=1` → native offline playback, no HLS juggling. python-plexapi: `Video.optimize(...)`. A single-request capped transcode download does **not** exist; custom segment-downloader is the L–XL fallback you can now skip. |
| [12](research/12-visionos-app-templates.md) | visionOS app templates | **Best starting template: Apple's `Destination Video` sample** — a 2D browse window + `AVPlayerViewController` docking into a custom Reality Composer Pro cinema environment = our exact design. Permissive Apple Sample Code License. Confirmed: **no OSS Plex visionOS client exists**; Swiftfin is iOS/tvOS-only (no native visionOS). |
| [13](research/13-playback-state-apis.md) | Playback-state APIs | The "real client" plumbing is **4 free endpoints**: `POST /playQueues` (for next-episode/shuffle) → read `viewOffset` to resume → `GET /:/timeline` heartbeat every ~10s (the only write path for resume/On Deck) → `GET /:/scrobble` to mark watched. Home screen = one `GET /hubs`. Gotcha: `key` is a path in timeline but a ratingKey number in scrobble. |

## The build decision (honest read)

- **Off-the-shelf might be enough.** If **Chroma** (downloads + transcode + theater) or **Theater** (best theater + reliable transcode, *if* its Plex downloads work) holds up in a hands-on test, **no build is needed.** That 10-minute test should happen before committing to code.
- **The real gap that justifies a build:** one app with **reliable transcoding AND confirmed Plex downloads AND a 3D SBS toggle**. No current app demonstrably has all three.
- **If we build, it's small** for priorities 1–3: `plexswift`-pattern API calls (hand-rolled) → `AVPlayerViewController` on a Cinema Environment. **3D SBS is the only genuinely hard piece**, and it's optional (only matters if you have 3D Blu-ray rips and care about them).
- **The ongoing tax:** free-Apple-ID sideloading means a **weekly, Mac-tethered re-sign** unless you buy the **$99/yr Apple Developer Program**. For an app you want to *keep using*, that $99 is effectively required eventually.

## What to gather (prerequisites)

**Must-have before you can build at all**
- macOS **26.2+** (the M5 MacBook Pro is fully supported — Apple silicon is required for visionOS dev)
- **Xcode 26.5** (bundles the visionOS SDK) + Command Line Tools
- A **free Apple ID** signed into Xcode (enough to run on the headset)
- A **Plex account** + reachable server (already have this)
- *(optional)* visionOS simulator runtime (~7 GB separate download)

**Needed before it's usable long-term**
- **Apple Developer Program — $99/yr** (kills the 7-day re-sign tax; adds TestFlight)
- **Plex Pass — NOT required for downloads** (corrected in round 3, supersedes the round-2 claim): the server-side **Media Optimizer** produces a capped-bitrate MP4 *version* in the **free** Plex edition, using its built-in "Optimized for TV – 8 Mbps 1080p" preset, which you then fetch with the free `?download=1` call. Plex Pass is only needed to *trigger* an optimize **remotely** (off-LAN) — and since you own the server and can optimize on-LAN/server-side, that's free. (Plex Pass / Remote Watch Pass is still separately needed for **off-LAN remote streaming**, not for downloads.)
- *(off-LAN remote streaming now needs Plex Pass / Remote Watch Pass; local-network playback stays free)*

**Dependency licenses** (all permissive — no copyleft concerns)
- `plexswift` — MIT, **but archived 2026-03-11** → vendor/fork it, expect to patch the JWT auth transition yourself
- `OpenImmersiveLib` — MIT (only needed if we ever add true 180/360 immersive playback — **not needed** for this library)
- `python-plexapi` — BSD-3-Clause (reference implementation only, not a dependency)

## Proposed architecture (from research/03)

```
PlexAVPApp (SwiftUI @main)
├── AppState            # observable app/session state (leaf)
├── PlexAuth            # PIN-OAuth, token in Keychain
├── PlexAPI             # library browse + transcode-decision (hand-rolled REST)
├── Player              # AVPlayerViewController wrapper + Cinema Environment
├── DownloadManager     # offline files in Application Support, background URLSession
└── LibraryUI           # Home · Libraries · Search · Detail (floating 2D window)
```

## Next steps

1. **Hands-on disqualify-or-confirm:** test **Theater** (does Plex-library download work?) and **Chroma** (is transcode reliable? any SBS?) against the real library. If one passes, the project may stop here.
2. **If a build is warranted:** run the brainstorming → design-spec → implementation-plan flow before any Swift is written.
3. **Decide on the $99 developer program** before depending on the app daily.

---

*Research generated 2026-06-08 via parallel research agents. All endpoint details for Plex transcoding are reverse-engineered/undocumented and version-dependent — verify against a live server.*
