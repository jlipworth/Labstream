# Competitive Teardown: Plex Clients for Apple Vision Pro (visionOS)

_Date: June 2026. Sources cited inline. Where a fact could not be confirmed from
developer statements, App Store listings, changelogs, or press/forum chatter, it is
marked **unconfirmed** rather than guessed._

## Scope

Apps analyzed:

- **Theater: Cinema & Events** — `id6502666560`
- **Aurora for Plex** — `id6547867554`
- **Chroma - Spatial Cinema** — `id6478800800`
- **Plexi** — `id6544807707`
- **Official Plex iPad app** (running in visionOS compatibility mode) — baseline reference

User priorities (in order):

1. Reliable **server-side transcoding** (client must request transcode robustly, not direct-play-only).
2. **Theater / immersive cinema environment** for FLAT 2D movies.
3. **Offline downloads of Plex-library items** (the key open question; rentals/purchases do not count).
4. Secondary: **3D SBS/TAB** toggle for 3D Blu-ray rips.

---

## Feature Matrix

| Feature | Theater: Cinema & Events | Aurora for Plex | Chroma - Spatial Cinema | Plexi | Official Plex iPad (compat) |
|---|---|---|---|---|---|
| **Server-side transcoding** | Yes — changelog v2.2 lists "transcoding" for Plex [1] | Yes — direct-plays natively-supported files, **falls back to server transcode** otherwise [2] | Yes — dev: "I lean on the Plex server to transcode files when necessary" [3] | **Direct-play-first.** Markets a "custom player to **skip transcoding**" [4][5]; server-transcode fallback **unconfirmed** | Yes — reference Plex client, full transcode support |
| **Theater/immersive env for 2D** | Yes — multiple (Nest, Eagle, home theater, 360° planetarium, fulldome) [1] | Minimal — "biggest screen" window scaling in system environments; no dedicated cinema room [2] | Yes — cinema with multiple rows + balcony/tilt mode [3] | Yes — Monolith Theater + Crimson Cinema (IAP) [4] | No theater environment (flat iPad window) |
| **Offline download of PLEX-LIBRARY item** | **Unconfirmed → likely NO for Plex.** v3.9 added "downloads & offline playback," but app also sells rentals/purchases; listing does not attribute downloads to Plex content [1][6] | **No** — absent from current shipped listing (v1.0.17, 06/2025); earlier "coming soon" chatter exists but **not shipped** [2][7] | **Yes (confirmed)** — "downloads and offline playback" is a core Plex feature; dev pitches airplane/no-connection use [3] | **Listed (yes), with caveat** — "download / play from file" advertised [4][5]; works via direct-play custom player; robustness **unconfirmed** | **Yes** — Plex's native Downloads/Mobile Sync (Plex Pass), the user's current known-good path |
| **3D SBS/TAB toggle** | **No** — reviewer: "there's no way to change the format to SBS" for Plex 3D [6] | No mention [2] | No SBS/TAB mention [3] | **Yes** — native 3D SBS VR (180/window) + real-time 2D→3D conversion (3D unlock IAP) [4][5] | No |
| **Pricing** | Free; **$3.99** unlock for YouTube+Plex; rentals $1.99–$14.99 [1][8] | **Free**, no IAP [2] | Free w/ 5-min limit; Pass **$2.99/mo** or **$29.99/yr** to remove limit + sync [3] | Free; theater unlocks $2.99–$3.99; **real-time 3D unlock $12.99** [4] | Free app; downloads require **Plex Pass** |
| **visionOS requirement** | 2.0+ [1] | 2.0+ [2] | **1.2+** [3] | 2.0+ [4] | (iPad app; runs in compat mode) |
| **Reliability chatter** | Praised as "best Plex player on AVP" by 9to5Mac [8]; no major transcode complaints surfaced; SBS gap noted [6] | "Simply works," responsive dev — **but** reviews cite transcoded-file playback issues + buffering after long pause [2][7] | Mixed: one reviewer 1→4 stars after dev fixes; download had early issues since improved; some format (MKV/HDR) gaps [3] | Too few ratings to display an overview [4]; direct-play model risks failures on unsupported codecs |
| **Dev responsiveness** | Very active — shipped to v3.10 (June 2026); frequent Plex enhancements [1] | Active, present on Reddit; small fixes through 2025 [2][7] | Active; iterated on reviewer feedback [3] | Active — v3.2.3 (Feb 2026), ongoing Plex-server compat fixes [4] | Plex stated (2024) it is **not** building a dedicated AVP app [9] |

---

## Per-priority read

### 1. Server-side transcoding (top priority)
- **Best fit: Theater, Aurora, Chroma** — all three explicitly request server transcode when a
  file is not natively playable [1][2][3].
- **Risk: Plexi** — its differentiator is a custom player that **skips** transcoding for
  direct play [4][5]. Whether it gracefully falls back to a server transcode for unsupported
  codecs is **unconfirmed**; this directly conflicts with priority #1 and is a real concern.
- Aurora has documented transcoded-file playback hiccups and post-pause buffering [2][7] —
  works, but not flawless.

### 2. Theater environment for flat 2D
- **Theater, Chroma, Plexi** all deliver genuine cinema rooms. **Aurora** only scales a
  flat window in system environments — weakest on this axis [2].

### 3. Offline Plex-library downloads (the key open question)
- **Chroma: SUPPORTED (confirmed)** — only app where Plex-library offline download is an
  explicit, unambiguous core feature [3].
- **Plexi: SUPPORTED but caveated** — "download / play from file" is advertised [4][5];
  tied to its direct-play model, robustness unconfirmed.
- **Theater: UNCONFIRMED, likely NO for Plex** — has downloads, but they appear scoped to
  the rentals/purchases storefront, not Plex-library items [1][6]. The brief does not let
  rental downloads count.
- **Aurora: ABSENT** — not in the current shipped listing [2][7].
- **Official Plex iPad app: SUPPORTED** — this is the user's existing known-good downloader.

### 4. 3D SBS/TAB (secondary)
- **Only Plexi** offers a true SBS/TAB 3D path [4][5]. Theater explicitly cannot [6];
  Aurora and Chroma do not advertise it.

---

## Does a build gap exist? — Verdict

**Probably not a clear-cut one — Chroma already closes the primary gap.**

The user's blocking pain is needing two apps (a cinema client + the official Plex app
purely to download big files on slow connections). The single decisive question is whether
any cinema-grade visionOS client can download **Plex-library** items offline:

- **Chroma does** — confirmed Plex-library downloads **plus** a real theater environment
  **plus** server-side transcode [3]. On paper Chroma satisfies priorities 1–3 in one app,
  which would eliminate the two-app workflow.
- **No single existing app cleanly covers all four priorities at once:**
  - Chroma = transcode + theater + downloads, **but no SBS/TAB 3D** (priority 4).
  - Plexi = theater + SBS/TAB 3D + downloads, **but direct-play-first** transcoding is the
    weak link against priority 1, and its download robustness is unconfirmed.
  - Theater = best theater + reliable transcode, **but no confirmed Plex download and no SBS**.
  - Aurora = clean transcode, **but weak theater and no downloads**.

**The ONE concrete gap that could justify a custom build:** a client that combines
**robust server-side-transcode-first playback** (priority 1) with **confirmed
Plex-library offline downloads** (priority 3) **AND** an **SBS/TAB 3D toggle** (priority 4)
in a **theater environment** (priority 2). No shipping app demonstrably does all four.
Plexi gets closest on 2+3+4 but compromises on 1; Chroma gets 1+2+3 but lacks 4.

**Recommendation:** Before committing to a custom build, **verify Chroma firsthand** — if its
Plex-library download + transcode reliability hold up, the two-app problem is solved and a
build is justified *only* by the secondary 3D-SBS want. If the user weights 3D SBS heavily,
the gap is real and a custom build (transcode-first player + Plex sync/download + SBS toggle
+ cinema env) is the only way to get all four in one app.

---

## Sources

1. Theater: Cinema & Events — App Store (US): https://apps.apple.com/us/app/theater-cinema-events/id6502666560
2. Aurora for Plex — App Store (US): https://apps.apple.com/us/app/aurora-for-plex/id6547867554
3. Chroma - Spatial Cinema — App Store (US): https://apps.apple.com/us/app/chroma-spatial-cinema/id6478800800
4. Plexi — App Store (CA): https://apps.apple.com/ca/app/plexi/id6544807707
5. Plexi developer (OPE Byte Sized Engineering): https://www.opebytesizedengineering.com/
6. Theater App Store user reviews (SBS / Plex-download limitations), via listing [1]
7. Aurora App Store reviews + version history (transcode/buffering, no downloads), via listing [2]
8. 9to5Mac, "The best Plex video player for Apple Vision Pro just got way better" (Jan 6, 2025): https://9to5mac.com/2025/01/06/the-best-plex-video-player-for-apple-vision-pro-just-got-way-better/
9. 9to5Mac, "Plex says it's not currently developing a dedicated Vision Pro app" (Feb 7, 2024): https://9to5mac.com/2024/02/07/plex-apple-vision-pro-app/
