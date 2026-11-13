# Licensed demo screenshots and review notes

Status: active; catalog provenance snapshot dated 2026-09-15, updated to the deployed
`open-films-v4` release on 2026-11-12. Official license pages were rechecked 2026-09-29 and Apple
screenshot classes on 2026-11-05. Final captures and clean-install candidate journeys remain
pending; the app logo and brand colors are being redone, so no final screenshots may be taken until
that work lands.
No screenshots were uploaded and no App Store Connect fields were changed by this work.

## Catalog release open-films-v4 — 2026-11-12

The two procedural samples no longer carry internal test names or sit beside the films:

- **Movies** holds only _Spring_ and _Wing It!_.
- A new **Samples** library holds _Audio and Subtitle Demo_ (was _Playback Diagnostics_ in Movies).
- The series in **Shows** is _Sample Series_ (was _Reviewer Fixtures_).

Both samples keep two audio tracks, English subtitles and three chapters, and now have 2:3 posters.
The open films and their four artwork crops are unchanged; the seed re-downloaded both films and
verified the six allowlisted hashes before activating the release. A review-account catalog read
confirmed the four libraries and five titles. `open-films-v3` (same day) was superseded because
Jellyfin dropped the word "Sample" from the video's displayed title. The public manifest records
`open-films-v4` and the matching source-manifest hash, and the review notes in `appstore/metadata/`
name the new titles. App Store Connect still holds the old notes until `asc-metadata.py push`.

## Review-server check — 2026-11-05 (read-only)

- **Catalog release:** the server serves `open-films-v2`. Versus `open-films-v1` only the procedural
  fixture generator changed (a second audio track); both open films and their four artwork crops
  are unchanged. The public manifest now records `open-films-v2` and the matching source-manifest hash.
- **Asset hashes:** all six allowlisted files (two complete encodes, two posters, two backdrops) in
  the live media volume match `scripts/app-review-media-provenance.json`, and the server's own
  23-entry runtime digest manifest verifies with no failures.
- **Reachability without a VPN:** the private hostname resolves through public DNS to public
  addresses only; from the capture host, traffic used the ordinary default interface (no VPN or
  exit node) through the proxied public edge, and returned trusted-TLS 200 responses for the
  public server-info endpoint and `/attribution`. The 15-minute public smoke CronJob was passing.
  An off-LAN device test (for example cellular) remains part of the reviewer-journey gate.
- **Attribution page:** live, byte-identical to its committed source, and names both films, their
  required credit lines, the CC BY 4.0 license link, the crop/resize modifications, and the
  no-endorsement statement.

The check read only Kubernetes object status and file hashes and made unauthenticated HTTPS reads.
It did not sign in, read Secrets, or write to the server. The address and credentials stay private.

## Decision and provenance

Use the already-deployed, Labstream-controlled Jellyfin review catalog, **not** the mutable public
Jellyfin demo. This preserves the intended open-film technique without inheriting shared progress,
download restrictions, or unverified third-party artwork. [Issue #280](https://github.com/jlipworth/Labstream/issues/280)
records the infrastructure close-loop; that does not prove any final client screenshots or hardware journey.
Do not reprovision it, reset shared progress, or change credentials without coordination.

The [public media manifest](../../scripts/app-review-media-provenance.json) records exact source URLs, complete
encode hashes, derived poster/backdrop hashes, crops, rights holders, and attribution. It is a
sanitized snapshot of infrastructure catalog `open-films-v1`, not a new live-server asset audit.
Retain the source-manifest hash and compare it with the deployed catalog before capture. The four
derived artwork files and two complete films are the storefront allowlist; procedural technical
fixtures are secondary review material, not evidence of broad codec coverage.

- **Spring:** complete official encode; poster/backdrop are crops of its frame at 180 seconds.
  The [official project page](https://studio.blender.org/projects/spring/pages/about/) permits
  commercial reuse under CC BY 4.0 with attribution, but excludes logos, trademarks and clearly
  third-party material. It describes the film as PG / suitable for ages six and older: do not assume
  the full catalog is appropriate for a 4+ presentation. Choose benign stills and have the release
  owner assess the age-rating questionnaire and available content.
- **Wing It!:** complete official encode; artwork derives from its frame at 150 seconds.
  Its [official licensing page](https://studio.blender.org/projects/wing-it/pages/licensing/) grants
  CC BY 4.0 commercial reuse subject to credit; logos, trademarks and third-party material are excluded.
- [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) requires appropriate attribution,
  a license link, and modification disclosure. Copyright permission does not imply endorsement or
  authorize every trademark or third-party element. Treat final composition as a separate approval.

Use these credit lines for the relevant films, alongside the license link and modification note:

> Spring — © Blender Foundation | cloud.blender.org/spring
>
> Wing It! — (CC) Blender Foundation | studio.blender.org
>
> Film images licensed under CC BY 4.0: https://creativecommons.org/licenses/by/4.0/.
> Catalog artwork cropped/resized from film frames; displayed within Labstream screenshots.
> No affiliation with or endorsement by Blender Foundation, Blender Studio, or the filmmakers.

The 2026-09-15 handoff recorded a review-service `/attribution` page; verify it before capture. A server-only page or a Git
manifest is not by itself a storefront credit: before uploading, approve an accessible public
credit placement accompanying the published images (for example the listing description and its
linked public credits page, or legible credits in an explicitly editorial screenshot frame).
Do not alter the app UI or paint replacement artwork over screenshots. If credits are composed
outside the real app capture, retain the untouched original and record the transformation.
Do not capture title cards, sponsor logos or end-credit logos as marketing artwork.

## Capture contract

Capture the actual submitted native app surfaces against this catalog, without `--ui-testing`,
synthetic browse fixtures, test-only overlays, or experimental P7. Record commit, marketing/build
version, configuration, OS/device family, surface, catalog release, source asset identity, capture
hash/dimensions, and editorial approval in an ignored manifest. Debug fixture captures remain
layout-only evidence; a filename or folder named `store-ready` does not make them final.

Before each family: ordinary sign-in, confirm Movies artwork is complete, verify only allowed
content is visible, and wait for loading/progress/system overlays to settle. Capture two stable
frames to detect transient loading. Do not publish account names, endpoints, QR/pairing codes,
network information, credentials, or personal-library material. Keep raw screenshots, results and
session configurations gitignored. Authentication screenshots never enter the export.

| Family | Required final lane | Intended real surfaces | Runner / remaining gate |
| --- | --- | --- | --- |
| iPhone | 1206 × 2622 (Dynamic Island medium, "6.3-inch") **and** 1320 × 2868 (Dynamic Island large, "6.9-inch") | Home/library, film detail, playback, downloads | `live` mode on the `iphone` and `iphone69` simulators; ordinary account login |
| iPhone Duo | 1398 × 2034 outer and 2007 × 2853 inner (required from April 2027) | Same as iPhone | `live` mode; a person unfolds the simulator for the inner display |
| iPad | 2064 × 2752 portrait, 13-inch | Library/sidebar, detail, playback | Semantic XCUITest; regular-width composition inspected separately |
| Mac | 2560 × 1600, 16:10 | Library, detail, windowed playback | Isolated host Accessibility/window-only capture; permissions, active window, production-equivalent branding |
| Apple TV | 3840 × 2160 or 1920 × 1080 | Movies, focused detail, playback | XCUITest/XCUIRemote; streaming only, no Downloads claims |
| Apple Vision Pro | 3840 × 2160 | Home, film detail, spatial playback | Passive capture; human navigation/authentication or headset for unsupported interaction |

Use three strong images per family as an editorial target, not a requirement to manufacture
unavailable views. Apple permits one to ten PNG/JPEG/JPG images per size with no alpha. Apple's
page (rechecked 2026-11-05) lists iPhone Dynamic Island (medium) as required and Face ID (large) as
required unless Dynamic Island (large) is provided, so supply both the 6.3- and 6.9-inch sets. A
13-inch iPad set is required. [The exporter](../APP-STORE-SCREENSHOTS.md) now validates
display-class coverage (`coverage --live-only`) and records live-session provenance, but it cannot
judge licensed-catalog authenticity or composition.

Acquire the lead's simulator/host playback lease; run one family at a time and shut it down
before the next. Never use the golden simulator as a substitute. On Xcode 27 do not coordinate-drive
visionOS. Do not reuse fixture or probe-only frames as if they showed the reviewer journey.
Use the exporter's `live start|shot|finish` lane: it launches the installed candidate with no
arguments, a person signs in and navigates, and each shot is bound to that process. macOS has no
live lane yet; capture its window by hand and apply the same size/hash/privacy checks.

## Review-note draft — fill private fields only in App Store Connect

This draft is not a claim that the exact candidate journey has passed. Rehearse and correct the
visible navigation labels separately for each family before copying it into review metadata.

Labstream is a client for Plex, Jellyfin and Emby; it does not supply a commercial media subscription.
For review, use the dedicated Jellyfin server and non-admin account supplied in the private review
fields. No personal server or account is needed. Choose Jellyfin, enter the supplied HTTPS server
address and credentials, then sign in using the app's normal login flow.

1. Open Movies, then Spring or Wing It!. Wait for the poster/backdrop, open details and play.
2. Pause/resume and seek; leave playback, reopen the same title and verify resume progress.
3. Browse Shows and Music. Use the Samples library's _Audio and Subtitle Demo_ (multiple tracks/chapters) to
   check subtitle/audio selection; do not imply the two open-film encodes supply every track type.
4. iPhone and iPad share the universal mobile binary but have different layouts. Mac is a native
   windowed app. Apple TV is streaming-only and intentionally has no Downloads/Offline destination.
   Vision Pro uses its own spatial shell; its interaction and playback require device acceptance.
5. The review backend is a dedicated sample environment. Its progress resets on a schedule; the
   owner will keep it available throughout review. Film licensing and artwork modifications are
   documented on the provided attribution page. Credentials and endpoint must remain private.

The separate offline/download acceptance work tracked in #259 is **deferred by the owner**. Do not
claim it passed, add it to this screenshot task, or silently remove the capability from review
access. If the submitted product still claims downloads, the release owner must explicitly decide
its remaining acceptance gate before submission.

## Close-out gates

- [x] Reuse deployed catalog rather than new/shared infrastructure; public provenance recorded.
- [x] Exact official license terms and current Apple size requirements checked.
- [ ] Obtain normal private review-account authentication in each isolated app session.
- [x] Verify deployed asset hashes and attribution (read-only, 2026-11-05).
- [ ] Bind captures to the exact release candidate; recheck hashes on the capture day.
- [ ] Capture and inspect actual catalog surfaces across all five families; no final images yet.
- [ ] Approve artwork, age suitability, storefront credit placement, composition and privacy.
- [ ] Rehearse exact reviewer instructions on clean candidate installs; preserve hardware gates.
- [ ] Release owner uploads approved images/notes and checks required display-class coverage.

## Historical handoff — 2026-09-15

At handoff, the screenshot worktree had a fresh, shutdown simulator and no installed review session.
That is not a current simulator inventory; provision and inspect the active capture lane before use.
Saved sessions in unrelated worktrees are not assumed to belong to the review account; durable
Jellyfin authentication is in Keychain and was not extracted. Once an owned candidate app is staged,
the least-invasive action is to enter the private review address/account directly into its normal
Jellyfin login, or approve its Quick Connect from an already authenticated review-server browser.
Never send these values through chat or inject an existing token.

No simulator was booted for the original provenance work or the 2026-09-29 consolidation. Fixture recapture would not resolve the actual
catalog/authentication gates and is intentionally not presented as progress toward final images.
