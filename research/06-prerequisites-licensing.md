# Prerequisites + Licensing Checklist — Native visionOS Plex Client (personal use)

_Compiled June 2026. Facts confirmed via web search against Apple Developer docs, Plex Support, and GitHub. Items flagged **[UNCERTAIN]** could not be fully verified and should be re-checked at build time._

Target machine: Apple Silicon **MacBook Pro (M5)**, **macOS 26.x ("Tahoe")**, an Apple Vision Pro, and a **free personal Apple ID**.

Legend for priority:
- 🟥 **MUST HAVE** — cannot build/run at all without it
- 🟧 **NEEDED LONG-TERM** — required for "keep it installed and actually use it"
- 🟦 **NICE TO HAVE** — quality-of-life / optional

---

## 1. Toolchain

- [ ] 🟥 **Xcode 26.x** (current release is **Xcode 26.5**). It bundles the **visionOS 26.5 SDK** (alongside iOS/iPadOS/tvOS/watchOS/macOS 26.5). visionOS apps must be built with the visionOS 26 SDK + Xcode 26 or later, so this is mandatory.
- [ ] 🟥 **macOS Tahoe 26.2 or later** to run Xcode 26.5. Your M5 / macOS 26.x machine satisfies this. ✅ Confirm you are on **26.2+** specifically (a 26.0/26.1 box would need a point-update first).
- [ ] 🟥 **Apple Silicon Mac** — required for visionOS development (Apple states "Developing for visionOS requires a Mac with Apple silicon"). M5 satisfies this. ✅
- [ ] 🟥 **Command Line Tools** — installed automatically with Xcode; you can also force-install via `xcode-select --install`. Needed for git, compilers, and Swift Package Manager from the terminal.
- [ ] 🟧 **visionOS Simulator runtime** — In recent Xcode, platform simulator runtimes are a **separate download** from the main app (managed in Xcode ▸ Settings ▸ Components). The visionOS runtime is roughly **~7 GB** historically. You will want it for fast iteration, but for THIS project you can also deploy straight to the physical Vision Pro.
  - Note: the **Simulator cannot fully exercise immersive/spatial video** the way real hardware can, so `OpenImmersiveLib` features really need on-device testing.
- [ ] 🟦 **Disk budget** — plan for **~40 GB+ free**. Xcode itself is smaller in the 26.x line (Apple cut the on-disk footprint ~25% starting in 26.0 beta 5), but each simulator runtime adds ~5–8 GB and DerivedData/archives grow over time.
- [ ] 🟦 Download size of the Xcode app itself: Apple does not publish an exact figure and it varies; budget the disk number above rather than the download number. **[UNCERTAIN — exact GB]**

**Verdict (toolchain):** M5 + macOS 26.x is fully supported. Only action items are confirming macOS ≥ 26.2, installing Xcode 26.5, and pulling the visionOS simulator component if you want it.

---

## 2. Apple Account Tiers

### Free Apple ID ("Personal Team" signing)
- ✅ **Can** build to and run on your own Vision Pro for personal testing (free on-device run is explicitly allowed and is "intended for testing purposes only").
- ❌ Provisioning profiles **expire after 7 days** → the app **stops launching** until you rebuild & re-deploy from Xcode (Mac-tethered re-sign).
- ❌ Limited App IDs (10) and **max 3 registered devices per platform**, each also 7-day-bound.
- ❌ **No TestFlight, no App Store distribution.**
- ❌ Some entitlements are unavailable to free teams (push notifications, certain background modes, associated domains, etc.).

### Apple Developer Program ($99/yr)
- ✅ **1-year** provisioning profiles → install once, app keeps working without weekly re-signing.
- ✅ TestFlight, broader entitlement access, App Store submission (not needed here, but available).

### Decision for THIS use case
- [ ] 🟥 **Free Apple ID is enough to START building and to verify the app runs on the headset.**
- [ ] 🟧 **For a "keep it installed and just use it" Plex client, the $99/yr Apple Developer Program is effectively required.** The free tier's 7-day expiry means you'd have to re-tether to the Mac and rebuild roughly weekly, which is impractical for a media player you want to grab and use. **Recommendation: start free, buy the $99 membership before you rely on it daily.**
  - 🟦 Mitigations if staying free: keep the Xcode project around and re-run weekly; some people script re-deploys, but the 7-day wall is unavoidable on the free tier.

---

## 3. Plex-Side Requirements

- [ ] 🟥 **A Plex account** (free) and a reachable **Plex Media Server** you administer or have access to.

### (a) Server-side transcoding
- ✅ **Basic transcoding is NOT gated by Plex Pass.** Standard transcoding works on a free Plex setup. (Plex Pass adds extras like **hardware-accelerated** transcoding, but software transcoding for normal playback is free.) Your client requests a transcode via the server API like any official app.

### (b) Offline downloads / mobile sync — **GATED** ⚠️
- ❌ **Downloads / offline sync REQUIRE Plex Pass.** Per Plex Support: *"The account signed into the mobile app must have a Plex Pass subscription or be a member of a Plex Home where the Home admin has an active Plex Pass,"* and *"in many cases the Plex Media Server admin must also have a Plex Pass."*
- This is a **server-/account-level entitlement enforced by Plex's backend**, not a client UI lock. A **third-party client using Plex's API is subject to the same gating** — the download/sync API endpoints will not grant offline media unless the relevant account/admin has Plex Pass. **You cannot code around this.**
- [ ] 🟧 **If offline downloads are a required feature → someone in the chain (you and/or the server admin) needs Plex Pass.** ($7/mo, $70/yr, ~$250 lifetime.)

### Remote streaming (newer 2025–2026 gate — relevant if the server is not on your LAN)
- ⚠️ Since **April 29, 2025**, **remote playback of personal media requires Plex Pass or the cheaper Remote Watch Pass** (~$1.99/mo / $19.99/yr) on the streaming user's account **or** the server admin's account. Rollout has been extending across platforms through 2026 (TVs/consoles enforced as of Apr 29, 2026).
- ✅ **Local-network (LAN) playback remains free.** If your Vision Pro and Plex server are on the same network, no pass is needed for streaming.
- [ ] 🟧 If you want to use this app **away from home**, factor in Plex Pass or Remote Watch Pass.

### One-time mobile "activation/unlock" fee
- The old **$4.99 one-time device activation fee** (to unlock playback in the official mobile apps without Plex Pass) is **being retired** as Plex rolls out its "new app experience." It applied to Plex's **own** apps, not third-party clients. A third-party client you write is **not** subject to that specific unlock fee. **[UNCERTAIN — exact final-removal date across all platforms; verify if it ever matters to you, but it does not gate a third-party build.]**

### API / Terms of Service for third-party clients
- Plex provides an **official API** (developer.plex.tv, OpenAPI spec) and authenticates via **`X-Plex-Token`** (now moving to **JWT** tokens). Plex publicly promoted third-party API access ("Plex Pro Week '25: API Unlocked"), so building a personal client is consistent with how the ecosystem works.
- ⚠️ There is **no separate "you may not build a client" prohibition** surfaced in support docs, but Plex's general **Terms of Service still apply**, and **feature entitlements (downloads, remote streaming) are enforced server-side regardless of client.** Treat the API as: *allowed to use, but cannot unlock paid entitlements.* **[UNCERTAIN — full ToS text not fetched; re-read Plex ToS before any redistribution. For private personal use this is low-risk.]**

**Plex verdict:** Free Plex covers local streaming + basic transcoding. **Offline downloads are hard-gated behind Plex Pass and a third-party client cannot bypass it.** Remote (off-LAN) streaming now also needs Plex Pass / Remote Watch Pass.

---

## 4. Open-Source Dependency Licenses

- [ ] 🟥 **`plexswift`** (github.com/LukeHagar/plexswift) — **MIT license.** Swift SDK over the Plex OpenAPI spec.
  - ⚠️ **Repository was ARCHIVED by the owner on 2026-03-11 — now read-only / unmaintained.** Implication: no upstream fixes for new Plex API/JWT changes. For a personal project that's acceptable, but plan to **fork/vendor it** and be ready to patch (especially around the JWT auth transition). MIT permits forking freely.
- [ ] 🟥 **`OpenImmersiveLib`** (github.com/acuteimmersive/openimmersivelib) — **MIT license.** Free/open-source spatial & immersive video player Swift Package for visionOS (by Anthony Maës / Acute Immersive, derived from "Spatial Player"). Actively the right building block for immersive playback.
- [ ] 🟦 **`python-plexapi`** (pushingkarma/pkkid) — **BSD-3-Clause.** Only relevant if you use it for scripting/prototyping; not part of a Swift app. Permissive.

**License implication for a personal project:** MIT and BSD-3-Clause are both permissive — free to use, modify, and vendor. The only practical attribution requirement is retaining the copyright/license notice. **No copyleft concerns.** The real risk is **maintenance**, not licensing: `plexswift` is archived, so budget time to maintain a fork.

---

## 5. Misc — Entitlements, Repo, Info.plist / ATS

- [ ] 🟦 **git + GitHub** for the repo. (No repo exists yet at this path — this is greenfield. `git init` when scaffolding.)
- [ ] 🟧 **Background Downloads / Background Modes entitlement** — if you implement offline downloads, you'll want `URLSession` background transfers. The relevant `UIBackgroundModes` is configured in Info.plist; background fetch/processing may need the **Background Modes** capability. ⚠️ Some background capabilities are **restricted on a free Personal Team** — another reason the $99 program helps long-term. **[UNCERTAIN — exact list of background modes blocked for free teams on visionOS; verify in Xcode's Signing & Capabilities.]**
- [ ] 🟧 **Networking / local network access** — connecting to a Plex server on the LAN will trigger the **Local Network privacy prompt**; add a usage-description string (`NSLocalNetworkUsageDescription`) and, if doing Bonjour discovery, declare `NSBonjourServices`.
- [ ] 🟥 **App Transport Security (ATS) for Plex connections** — important detail:
  - Plex servers are reachable over **`http://` on the LAN**, or over HTTPS using Plex's **`*.plex.direct`** certificates. Plex issues a real, publicly-trusted wildcard-style cert mapped to your server's IP via `*.plex.direct` DNS, so **HTTPS to `plex.direct` generally satisfies ATS without exceptions** — clients should **prefer the `plex.direct` HTTPS URI** the Plex API hands back rather than raw IP/http.
  - If you must hit the server over **plain http** (e.g., direct LAN IP, no `plex.direct`), you'll need an **ATS exception** in Info.plist (e.g., `NSAllowsLocalNetworking`, or a scoped `NSExceptionDomains` entry). Prefer the narrowest exception; avoid a blanket `NSAllowsArbitraryLoads`.
  - **Recommended pattern:** use the connection URIs from Plex's `/resources` (the official apps do this) and connect via `plex.direct` HTTPS to stay ATS-clean; only add `NSAllowsLocalNetworking` as a fallback for http LAN access.
- [ ] 🟦 No special **App Review entitlement requests** are needed for a personal/sideloaded build (those matter for App Store distribution, which isn't the goal here).

---

## Consolidated "Before You Scaffold" Summary

**🟥 Must have before you can build at all**
1. macOS Tahoe **≥ 26.2** on the M5 (confirm point version).
2. **Xcode 26.5** (includes visionOS 26.5 SDK) + Command Line Tools.
3. **Free Apple ID** signed into Xcode (enough to run on the Vision Pro).
4. A **Plex account + reachable Plex Media Server**.
5. Dependencies decided: **`plexswift` (MIT, archived — vendor it)** + **`OpenImmersiveLib` (MIT)**.
6. **ATS plan**: connect via `plex.direct` HTTPS; add `NSAllowsLocalNetworking` only if using http LAN.

**🟧 Needed before it's usable long-term**
1. **$99/yr Apple Developer Program** — to escape the 7-day free-signing expiry for a keep-it-installed app.
2. **Plex Pass** (or **Remote Watch Pass** for remote-only) **if** you need **offline downloads** (Pass-gated, unavoidable) or **off-LAN streaming**.
3. **Background Modes + Local Network** entitlements/usage strings (downloads + LAN discovery).

**🟦 Nice to have**
1. visionOS **simulator runtime** (~7 GB) for fast iteration.
2. **git/GitHub** repo hygiene; **python-plexapi** (BSD-3) for prototyping only.

---

## Sources
- [Xcode SDK & system requirements — Apple Developer](https://developer.apple.com/xcode/system-requirements/)
- [Xcode 26 release notes — Apple Developer](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- [Provisioning profile updates (free team limits) — Apple Developer](https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates/)
- [Compare memberships — Apple Developer](https://developer.apple.com/support/compare-memberships/)
- [Downloads / Sync FAQ — Plex Support](https://support.plex.tv/articles/downloads-sync-faq/)
- [Downloads Overview — Plex Support](https://support.plex.tv/articles/downloads-overview/)
- [Requirements for Remote Playback of Personal Media — Plex Support](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/)
- [Remote Watch Pass Overview — Plex Support](https://support.plex.tv/articles/remote-watch-pass-overview/)
- [Important 2025 Plex Updates — Plex blog](https://www.plex.tv/blog/important-2025-plex-updates/)
- [Plex dropping mobile activation fees — TheDesk](https://thedesk.net/2025/03/plex-dropping-mobile-activation-fees/)
- [Unlocking/Activating Plex for iOS — Plex Support](https://support.plex.tv/articles/205556278-unlocking-or-activating-plex-for-ios/)
- [Finding an authentication token / X-Plex-Token — Plex Support](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)
- [Plex Pro Week '25: API Unlocked — Plex blog](https://www.plex.tv/blog/plex-pro-week-25-api-unlocked/)
- [Plex Media Server API — developer.plex.tv](https://developer.plex.tv/pms/)
- [plexswift (MIT, archived 2026-03-11) — GitHub](https://github.com/LukeHagar/plexswift)
- [OpenImmersiveLib (MIT) — GitHub](https://github.com/acuteimmersive/openimmersivelib)
- [python-plexapi (BSD-3-Clause) — GitHub](https://github.com/pushingkarmaorg/python-plexapi)
