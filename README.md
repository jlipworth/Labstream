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
- **Plex Pass** *only if* you use the official Mobile Sync download path; the simple `download=1` fetch this app would use does **not** require it
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
