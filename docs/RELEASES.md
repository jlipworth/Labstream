# Release and App Store status

This page is the public source of truth for Labstream's distribution status and the release
checks that can safely live in the repository. It does not contain signing identities, App Store
Connect contact details, review credentials, tokens, private server addresses, or other secrets.
Statements about processed builds and App Store Connect are repository records, not a live account
query; verify them in App Store Connect again before any upload or submission.

## Current status

On 2026-10-22, the next internal TestFlight run built **1.8.0 (build 1561)** for all four
platforms from clean commit `a9ab14f4` on `downloads/overhaul`, using
`--allow-unpublished`. It adds query-consistent Search presentation and bounded title
ranking, plus owned download-test fixture cleanup. The keychain and download-backlog
investigations in this source do not change production behavior. All four archives passed
validation and processed to **VALID**, **IN_BETA_TESTING**, in **Labstream Internal**.
No App Store build was selected or submitted for review. Two complete Mac hosted runs,
iPhone/tvOS Search tests, four-platform runtime checks, and repository hygiene passed;
physical-device and live-backend acceptance remain separate.

On 2026-10-22, an internal TestFlight run built **1.8.0 (build 1555)** for all four
platforms from clean commit `00614949` on `downloads/overhaul`, using
`--allow-unpublished`. This includes the Mac navigation and window-close fixes, Home shelf
layout corrections, and workflow tooling improvements. All four archives passed signing,
entitlement, version, and matching privacy-manifest checks. All four builds processed to
**VALID**, reached **IN_BETA_TESTING**, and are available in **Labstream Internal**.
No App Store build was selected or submitted for review. Physical-device and live-backend
acceptance remain open; the source commit is local and is not yet on `origin/main`.

The repository source on the downloads-overhaul stack is **1.8.0 (build 2)** across all four app
targets. 1.8.0 is the downloads overhaul (P1–P7): download admission, cleanup and lifecycle
durability, storage accounting, bounded background wakes, offline playback and shared download rows;
see the [bugs-versus-main audit](https://github.com/jlipworth/Labstream/blob/main/docs/evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md). On 2026-10-17 a `ship` run
built clean **1.8.0 (build 1523)** archives for all four targets from `49e186f0` on the
`downloads/overhaul` integration branch (not yet on `main`; uploaded with `--allow-unpublished`).
All four processed to **VALID**, are in beta testing, and are in the internal TestFlight group.
They are TestFlight builds only: no 1.8.0 App Store version exists, nothing was selected, and
nothing was submitted for review. On 2026-10-18 a second `ship` run built clean **1.8.0
(build 1537)** archives for all four targets from `12466ea1` on the same branch, also uploaded with
`--allow-unpublished`. It adds:

- foreground recovery for background-created range tasks that crawl after the app was off-head
  or backgrounded ([#409](https://github.com/jlipworth/Labstream/issues/409));
- fixed Pause All / Resume All for mixed queues
  ([#410](https://github.com/jlipworth/Labstream/issues/410));
- posters for queued rows ([#412](https://github.com/jlipworth/Labstream/issues/412));
- the configurable simultaneous-download limit
  ([#404](https://github.com/jlipworth/Labstream/issues/404));
- aggregate speed after sleep ([#379](https://github.com/jlipworth/Labstream/issues/379));
- the single-line finished-row summary.

All four processed to **VALID** and are in beta testing in the internal TestFlight group, again
with nothing selected or submitted. Later on 2026-10-18 a third `ship` run built **1.8.0 (build
1541)** for all four targets from `25bc6917`. It adds one change: every queued Plex optimize or Emby
Convert job is submitted to the server at once, so a batch renders while the app is suspended,
and finished renders wait for a transfer slot
([#414](https://github.com/jlipworth/Labstream/issues/414)). It shipped the same way: **VALID**,
internal group only, nothing selected or submitted. A fourth `ship` run built **1.8.0 (build 1543)**
for all four targets from `4dc82ede`. It moves the restricted Offline status into navigation chrome
(a "Server unreachable" subtitle or visionOS toolbar label plus a Reconnect toolbar action) so it no
longer covers the title or toolbar ([#415](https://github.com/jlipworth/Labstream/issues/415)). It
shipped the same way: **VALID**, internal group only, nothing selected or submitted. A fifth `ship`
run built **1.8.0 (build 1545)** for all four targets from `6c14515d`. It keeps the aggregate
download speed visible across static Range segment boundaries instead of showing "Updating speed…"
every segment ([#416](https://github.com/jlipworth/Labstream/issues/416)). It shipped the same way:
**VALID**, internal group only, nothing selected or submitted. Device acceptance and landing on `main` are tracked in
[#403](https://github.com/jlipworth/Labstream/issues/403). PMSKit has no app-version constant; the
runtime client identity reads the bundle version and falls back to `0.0.0`.

The previous source was **1.7.2 (build 2)** across all four app targets. Build 2 supersedes the never-uploaded build 1 source so the next archive set carries its
own build number; the `v1.7.2` tag remains the build 1 source milestone. On 2026-10-14, clean
Apple Distribution–signed **1.7.2 (build 2)** Release archives for all four targets were built
from `ce97958f` with stable Xcode 27, validated as described in the
[publication sequence](#coordinated-publication-sequence), and uploaded to App Store Connect
through Xcode Organizer. All four uploads processed to **Ready to Submit**, are available to
the internal TestFlight group, and were selected for their 1.7.2 platform versions on
2026-10-14. Build 1 was never uploaded. Earlier local 1.7.2
correction archives were signature-checked, but they are not the original tagged binaries.
The pre-integration clean correction set was built from `07fba33d`; it must not be
presented as a binary of the subsequently reconciled source. Local-main integration retains
stop-item detachment, truthful proxy statistics, subtitle preference handling and safe
plain-language error explanations. The older automatic P7 rewrite is superseded by the
default-off DEBUG macOS experiment; prior local commits remain in history. Readable Xcode
aggregate privacy reports were generated from the four exact build 2 archives. The reports agree
with the published label, and every packaged app manifest declares SystemBootTime `35F9.1`.
Prior archive sets are not substitutes for these checks.
On 2026-10-15 the first command-line run of `scripts/testflight-release.py ship` built clean
**1.7.2 (build 1490)** archives for all four targets from `4c8de88c`, using the commit-count
build number (`--build-number auto`) without a version-bump commit. All four uploads processed
to **VALID**, are in beta testing, and are in the internal TestFlight group. They are TestFlight
builds only: every 1.7.2 platform version still has build 2 selected, and selecting 1490 instead
needs separate approval. The Mac upload first failed because the `.pkg` export lacked the
installer signing identity; after that fix landed it was retried from the same archive.
On 2026-10-16 a second `ship` run built clean **1.7.2 (build 1501)** archives for all four
targets from `4b65b353`, after the offline launch gate (#355), the iOS player chrome fix (#356),
and the corrected App Review notes (#359) merged. All four uploads processed to **VALID**, are
in beta testing, and are in the internal TestFlight group. They are TestFlight builds only and
are not selected for the platform versions.
A third `ship` run the same day built clean **1.7.2 (build 1503)** archives for all four targets
from `b63d1757`, after the Emby/Plex season-download admission fix (#363) merged. All four
processed to **VALID**, are in the internal TestFlight group, and were selected for their 1.7.2
platform versions with `select-build --yes`, replacing build 2. Nothing was submitted for review.
A fourth `ship` run the same day built clean **1.7.2 (build 1506)** archives for all four targets
from `6faff16f`, after the player Stats signal-chain redesign (#367) merged. All four processed to
**VALID** and are in the internal TestFlight group. They are TestFlight builds only and are not
selected for the platform versions.
A `ship` run on 2026-10-17 built clean **1.7.2 (build 1513)** archives for all four targets from
`43196be4`, after the first performance pass (#372, #373, #377, #378) and the tvOS UI-test build fix
(#370) merged. All four processed to **VALID** and are in the internal TestFlight group. They are
TestFlight builds only and are not selected for the platform versions.
The latest recorded processed distribution is the **1.7.2 (build 1513)** archive set at
`43196be4`; the selected review candidate remains the **1.7.2 (build 1503)** set at `b63d1757`
(the earlier candidate was build 2 at `ce97958f`), and
the previous release was the **1.6.1 (build 2)** set at `abd1ddcac351`. Keep the source version
and the processed binary version separate when reporting release status. Later `auto` builds
and any hand-bumped `CURRENT_PROJECT_VERSION` for 1.7.2 must exceed 1513.

| Product | Current source | Latest recorded processed distribution |
| --- | --- | --- |
| Apple Vision Pro (`Labstream`) | 1.8.0 (build 2) | **1.7.2 (build 1513):** a clean `43196be4` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1506):** a clean `6faff16f` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1503):** a clean `b63d1757` archive is processed, selected for the platform version, and in the internal TestFlight group. **1.7.2 (build 2):** the repository records a clean `ce97958f` archive uploaded and processed, previously selected for the platform version, and available to the internal TestFlight group. **1.7.2 (build 1490)** from `4c8de88c` and **1.7.2 (build 1501)** from `4b65b353` are also processed and in the internal group, not selected. Physical TestFlight acceptance and review access remain pending. |
| iPhone and iPad (`LabstreamMobile`) | 1.8.0 (build 2) | **1.7.2 (build 1513):** a clean `43196be4` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1506):** a clean `6faff16f` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1503):** a clean `b63d1757` archive is processed, selected for the platform version, and in the internal TestFlight group. **1.7.2 (build 2):** the repository records a clean `ce97958f` universal iOS archive uploaded and processed, previously selected for the platform version, and available to the internal TestFlight group. **1.7.2 (build 1490)** from `4c8de88c` and **1.7.2 (build 1501)** from `4b65b353` are also processed and in the internal group, not selected. Physical iPhone and iPad acceptance remain pending. |
| Apple TV (`LabstreamTV`) | 1.8.0 (build 2) | **1.7.2 (build 1513):** a clean `43196be4` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1506):** a clean `6faff16f` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1503):** a clean `b63d1757` archive is processed, selected for the platform version, and in the internal TestFlight group. **1.7.2 (build 2):** the repository records a clean `ce97958f` archive uploaded and processed, previously selected for the platform version, and available to the internal TestFlight group. **1.7.2 (build 1490)** from `4c8de88c` and **1.7.2 (build 1501)** from `4b65b353` are also processed and in the internal group, not selected. Physical Apple TV acceptance remains pending. |
| Mac (`LabstreamMac`) | 1.8.0 (build 2) | **1.7.2 (build 1513):** a clean `43196be4` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1506):** a clean `6faff16f` archive is processed and in the internal TestFlight group, not selected. **1.7.2 (build 1503):** a clean `b63d1757` archive is processed, selected for the platform version, and in the internal TestFlight group. **1.7.2 (build 2):** the repository records a clean `ce97958f` archive uploaded and processed, previously selected for the platform version, and available to the internal TestFlight group. **1.7.2 (build 1490)** from `4c8de88c` and **1.7.2 (build 1501)** from `4b65b353` are also processed and in the internal group, not selected. A 1.7.2 TestFlight install on a Mac is not recorded; the earlier 1.6.1 (build 2) build was installed from TestFlight and passed launch and receipt/signature checks. Deeper sandbox and live-host acceptance remain pending. |

The 1.7.1 source milestone includes bounded DV/HDR delivery investigation and probe
validation. The P7 HDR10-base candidate remains default-off and DEBUG-only on macOS;
full-suite and cross-backend/hardware acceptance gates remain open in the
[DV investigation](https://github.com/jlipworth/Labstream/blob/main/docs/research/dv-p7-decoder-boundary.md). No release tag, upload, or
distribution is authorized by the version increment.

The four targets share the neutral `org.labstream.Labstream` bundle identifier and are intended
for one App Store Connect universal-purchase record. The earlier private visionOS 1.6.0 build used
a retired personal-namespace identifier; it is not the publication record for 1.6.1 and cannot be
migrated because Apple freezes a record's bundle identifier after its first build upload.

The publication topology is one product record with four platform versions and four binary
archives: the `LabstreamMobile` iOS archive covers both iPhone and iPad, while visionOS, tvOS, and
macOS each use their own archive. Metadata, screenshots, build selection, review notes, and
acceptance remain platform-specific even when the platforms share one purchase record. A platform
must not be marked ready merely because another platform passed review.

The earlier recorded App Store Connect state included the shared app information, free price
schedule, a **Data Not Collected** privacy answer, platform descriptions, review contacts,
build selections, manual-release settings, and one privacy-safe synthetic placeholder screenshot for
each submitted device family. Those screenshots prove the capture and upload path, but they are not
the intended public product-page set. In that recorded state, app availability was not enabled.
Licensed demo media, final screenshot capture and review, demo review access, review notes,
physical-platform acceptance, storefront scope, Digital Services Act status where applicable, and
final submission remain open.

`1.8.0` is the current source marketing version (`CFBundleShortVersionString`). The number in
parentheses is the App Store build number (`CFBundleVersion`). A new marketing version begins at
build 1; each replacement upload for the same platform and marketing version must use a higher
build number. The repository's
[`bump-version` skill](https://github.com/jlipworth/Labstream/blob/main/.claude/skills/bump-version/SKILL.md)
owns the per-platform bump, tagging, and verification procedure.

## Current release audit and deferred scope

The [2026-09-15 disclosure audit](https://github.com/jlipworth/Labstream/blob/main/docs/evidence/audits/2026-09-15-prerelease-disclosure-audit.md)
is a historical source audit, not current account certification. Its wording and required-reason
API fixes landed in PRs #329 and #328. The October 2026 continuation applied the
owner-approved collection mapping and generated readable Xcode aggregate reports from all
four fresh, distribution-signed local correction archives. The shared App Store Connect
privacy label was published and reloaded to verify the seven declared data types, linked to
users, with tracking off. Functionality is declared for all seven; user ID, device ID and
product interaction also declare personalization. The tvOS binary manifest omits crash
summaries because that MetricKit path is absent on tvOS.

This resolves the exercised blank-report generation problem, not every privacy or release
gate. Received support storage outside GitHub and end-to-end demo database/log/edge/backup
retention remain unverified. The updated Apple TV policy was saved for the next app version.
All four App Store Connect version drafts now show 1.7.2, with descriptions that identify
the separate optional demo service. On 2026-10-14 each draft was switched from the
inherited 1.6.1 (build 2) binary to 1.7.2 (build 2); the drafts are still not
submission-ready. Review access remains unverified.
The updated public policy is live on GitHub Pages, deployed from `main` at `52afc52` on
2026-10-15. A fresh issue-state check found
[#325](https://github.com/jlipworth/Labstream/issues/325) already closed externally; that status
is not evidence that the retention/storage uncertainties above were resolved.
[#326](https://github.com/jlipworth/Labstream/issues/326) stayed open until the exact signed
build 2 archive reports were checked on 2026-10-14.

[#259](https://github.com/jlipworth/Labstream/issues/259), disconnected cold-launch access to
completed downloads, was **deferred by user decision** for the 1.7.2 (build 2) candidate. The
typed session-restore offline launch gate (PR #355) is now on `main` for the next candidate, but
physical-device acceptance is open: keep the issue open and do not advertise reliable offline
cold launch as verified.

The [licensed-media capture plan](https://github.com/jlipworth/Labstream/blob/main/docs/plans/2026-09-15-store-demo-capture.md)
retains final screenshots, storefront attribution, age suitability and clean-install reviewer
journeys as open gates. Recorded provenance is not a fresh deployed-catalog hash check.

## 1.7.2 release-candidate scope

The coordinated **1.7.2 (build 2)** candidate includes the merged playback-error and
bounded-cleanup work, required-reason uptime declaration, and current disclosure and
screenshot guidance. Build 2 adds the Search-stack reset for ⌘F and new macOS toolbar
queries over a pushed result ([#334](https://github.com/jlipworth/Labstream/issues/334));
the iPad/visionOS ⌘F entry point ([#335](https://github.com/jlipworth/Labstream/issues/335))
remains open.

The release owner explicitly deferred these issues for this candidate on 2026-09-29:

- [#324](https://github.com/jlipworth/Labstream/issues/324): HEVC Rext 4:4:4 playback
  and the observed Jellyfin server-worker cleanup race;
- [#322](https://github.com/jlipworth/Labstream/issues/322): Emby P8 deep-seek
  investigation and remaining controlled validation;
- [#258](https://github.com/jlipworth/Labstream/issues/258): iOS player-chrome
  size/position changes and clipping. The stable safe-area envelope (PR #356) is now on `main`
  for the next candidate; physical iPhone confirmation remains open (see
  [MOBILE-IOS.md](MOBILE-IOS.md)).

These are accepted deferrals, not fixes or passing acceptance results. Keep the issues
open and preserve their evidence. The #259 offline-cold-launch deferral above applies to this
candidate too. [#331](https://github.com/jlipworth/Labstream/issues/331), Stats
readability redesign, is low-priority follow-up and not a release blocker.

Candidate preparation does not close the physical-device, privacy/disclosure,
signed-archive report, screenshot, reviewer-access, or Account Holder gates below.
TestFlight upload and App Review submission require separate authorization.

### Local correction validation

Hermetic PMSKit, repository hygiene, iPhone/tvOS hosted tests, the Mac suite under default
parallelism, iPhone/iPad/tvOS semantic fixtures and the passive visionOS fixture passed for the
candidate on installed beta simulator runtimes. The Emby stop-before-reopen ordering work does not
prove server worker exit; see the
[ordering investigation](https://github.com/jlipworth/Labstream/blob/main/docs/evidence/audits/2026-10-04-emby-reopen-session-overlap.md).
Exact source-matched cross-backend parity, audible output, subtitles, next-episode behavior,
broader source coverage, physical iPad/Vision Pro/Apple TV and TestFlight acceptance remain open.

## Coordinated publication sequence

For a new coordinated archive set or the first public release, use this order. If the neutral
App Store Connect record already exists, verify it and add the required platform version instead of
creating a duplicate record:

1. In the Apple Developer account, confirm the neutral App ID and required capabilities, then make
   an Apple Distribution signing identity and platform-appropriate App Store provisioning available
   to Xcode. Do not commit certificates, private keys, profiles, account identifiers, or exports.
2. Create the new App Store Connect app for `org.labstream.Labstream`, then add the visionOS,
   iOS/iPadOS, tvOS, and macOS platform versions to that one universal-purchase record. Do not reuse
   the retired personal-identity visionOS record.
3. From the exact public release commit, produce and locally validate one archive each for
   `Labstream`, `LabstreamMobile`, `LabstreamTV`, and `LabstreamMac`. Confirm identity, version,
   build, entitlements, minimum OS, architecture, and device family before upload.

   Use `scripts/testflight-release.py` for steps 3 and 4 (the `testflight-deploy` skill
   documents the flow). `preflight` checks clean published source, per-scheme version/build,
   App Store profiles, the Apple Distribution identity, and that the build number is not already
   uploaded. `archive` writes manual-distribution-signed archives to Xcode's Organizer folder,
   `validate` checks each archive plus the four-app privacy manifest comparison, and
   `upload --yes` uploads with an App Store Connect API key.
   `distribute --group <internal group> --yes` adds already-processed builds to an internal
   TestFlight group. Organizer remains the place to generate the aggregate privacy report. For an on-demand build to internal testers,
   `ship --group <internal group> --yes` runs the whole sequence with `--build-number auto`
   (the commit count of HEAD) and adds the processed builds to that group; a release candidate
   can then be one of those builds, selected for review rather than archived again. Successful
   ships prune local archives to the newest three uploaded sets plus any set attached to an App
   Store version (`prune-archives` dry-runs the same policy).

   The script exists because Xcode 27 `xcodebuild` cannot use an account signed in through Xcode
   Settings ▸ Apple Accounts (`No Accounts`), and tvOS automatic signing fails while the team has
   no registered Apple TV. It therefore signs manually and scopes the profile to the app target,
   because Swift package targets reject a global `PROVISIONING_PROFILE_SPECIFIER`.

   The API key lives in 1Password and is read through a read-only service account whose token is
   kept in the login Keychain; local references stay in the gitignored `scripts/asc.local.env`.
   The key is written only to a private temporary file for the duration of a command. Never
   commit or publish the key, its identifiers, the team ID, or the service-account token.
4. Upload each archive and wait for App Store Connect processing. Treat warnings or missing
   platform associations as blockers; do not advance a different binary merely because it shares
   the version number. `scripts/testflight-release.py status --wait` reports processing,
   TestFlight state, and beta groups. A new platform version can inherit the previous version's
   build; `select-build` shows which versions still point at an older build and `--yes`
   attaches the new one. It never submits for review.
5. Establish the reviewer environment and its licensed sample-media inventory, then capture and
   privacy-review the final platform-specific screenshot sets. Complete shared app information plus
   platform metadata, build selection, privacy/export answers, review notes, and review access.
   Product-page text and review notes live in `appstore/metadata/` and are edited by pull request;
   `scripts/asc-metadata.py diff` compares them with App Store Connect and `push --yes` writes the
   reviewed text. Review contact details, demo credentials, and the review server address stay only in
   App Store Connect.
6. Install processed builds through TestFlight on every submitted device family, starting from a
   fresh install for the identity boundary and sign-in checks. Record the platform-specific gates
   below.
7. Add only accepted platform versions for review. The final submit action and storefront scope
   remain Account Holder decisions.

## Reviewer environment

App Review needs a reproducible path that does not depend on a private home network, short-lived
token, personal media library, VPN, or reviewer-created server. Prefer a dedicated review account
and a small non-personal library whose media and artwork are licensed for this use. The environment
must support the same backend choice and core browse/play journey documented in the review notes
and remain available throughout review.

A public Jellyfin demonstration service may be evaluated as a candidate, but it is not automatically
an acceptable dependency: confirm the operator permits App Review use, credentials are stable,
Apple networks can reach it, and the sample library exercises the submitted clients. If any of
those conditions is uncertain, run a dedicated review-only Jellyfin instance instead. Keep its
credentials only in App Store Connect. Test the final instructions from clean installs on Vision
Pro, iPhone, iPad, Apple TV, and Mac before submission.

The reviewer and screenshot lane is the Labstream-controlled Jellyfin review catalog chosen in the
[licensed-media capture plan](https://github.com/jlipworth/Labstream/blob/main/docs/plans/2026-09-15-store-demo-capture.md)
([#280](https://github.com/jlipworth/Labstream/issues/280)). The 2026-08-22 evaluation of the
official stable public demo established compatibility only; Labstream supports its passwordless
Jellyfin login as of [issue #283](https://github.com/jlipworth/Labstream/issues/283). It was not
adopted because its shared account is mutable, downloads are disabled, service resets can
interrupt sessions, and permission for third-party App Store marketing screenshots is unverified.

Prefer a Labstream-controlled review instance with a deterministic catalog of original,
public-domain, or appropriately Creative Commons media. Record every title, artwork source,
license, attribution requirement, and permitted screenshot/review use in a repository manifest;
do not use commercial movie or television artwork merely because a metadata provider can return
it. The same catalog should drive automated screenshots and the reviewer journey so the captured
UI matches the environment Apple can actually test.

## Apple-platform release checklist

### Repository and binary

Checked boxes below reflect the latest recorded evidence; re-verify external account, TestFlight,
and App Store Connect state before relying on them for a new submission.

- [ ] The release commit contains no credentials, private endpoints, signing files, diagnostic
      bundles, or personal media data, including in newly added files.
- [ ] `PMSKit` hermetic tests, repository hygiene, strict MkDocs, and the affected native test
      matrix pass.
- [x] The previous processed **1.6.1 (build 2)** Release archives were produced for iOS/iPadOS,
      visionOS, tvOS, and macOS with the intended Xcode release and Apple Distribution signing;
      every archive reports the neutral bundle identifier and expected marketing version/build.
- [x] The previous processed **1.6.1 (build 2)** archives are reproducible from their exact public
      release commit. If that commit changes after a preflight archive, rebuild rather than treating
      the older archive as the submission binary.
- [x] The previous processed **1.6.1 (build 2)** platform archives pass Xcode validation and App Store
      Connect processing without compliance or binary warnings.
- [x] Each selected **1.6.1 (build 2)** App Store Connect build reports the intended minimum OS,
      device family, entitlements, and supported architecture.
- [x] Clean Release archives for the current **1.7.2 (build 2)** source were produced from
      `ce97958f`, validated, and uploaded for all four platforms on 2026-10-14.
- [x] App Store Connect processing completes without compliance or binary warnings for every
      **1.7.2 (build 2)** upload, and each build is selected for its platform version.
- [x] Clean **1.7.2 (build 1490)** archives from `4c8de88c` were built, validated, uploaded, and
      processed for all four platforms on 2026-10-15 through `scripts/testflight-release.py`, and
      added to the internal TestFlight group. They are not selected for the platform versions.
- [x] Clean **1.7.2 (build 1501)** archives from `4b65b353` were built, validated, uploaded, and
      processed for all four platforms on 2026-10-16 through `scripts/testflight-release.py ship`,
      and added to the internal TestFlight group. They are not selected for the platform versions.
- [x] Clean **1.7.2 (build 1503)** archives from `b63d1757` were built, validated, uploaded, and
      processed for all four platforms on 2026-10-16, added to the internal TestFlight group, and
      selected for each 1.7.2 platform version.
- [x] Clean **1.7.2 (build 1506)** archives from `6faff16f` were built, validated, uploaded, and
      processed for all four platforms on 2026-10-16 and added to the internal TestFlight group.
      They are not selected for the platform versions.
- [x] Clean **1.7.2 (build 1513)** archives from `43196be4` were built, validated, uploaded, and
      processed for all four platforms on 2026-10-17 and added to the internal TestFlight group.
      They are not selected for the platform versions.
- [ ] A physical Vision Pro TestFlight smoke covers first launch, sign-in, browse, playback,
      seeking, subtitles, audio, Cinema, background/foreground, and diagnostics. Simulator smoke
      is useful but does not replace this gate.
- [ ] Physical iPhone and iPad TestFlight smokes cover compact and regular-width navigation,
      sign-in, playback, downloads, lifecycle, diagnostics, and accessibility.
- [ ] A physical Apple TV TestFlight smoke covers Siri Remote focus/input, sign-in, browse,
      playback, long-play behavior, audio/HDR routing, lifecycle, and accessibility. Downloads are
      intentionally absent from this platform.
- [ ] A TestFlight Mac smoke covers sandboxed sign-in, browse, playback, keyboard/media keys,
      window lifecycle, downloads, diagnostics, and accessibility on the supported architectures.
- [ ] The release commit is publicly available as corresponding GPLv3 source. Create the annotated
      coordinated tag `vX.Y.Z` only after the version commit exists and tagging is authorized.

### Product-page metadata

- [ ] App name, subtitle, category, age rating, description, keywords, copyright, and availability
      are complete and match the product that was tested.
- [x] The description states that Labstream connects to a server selected by the user, provides no
      media, and is unofficial and unaffiliated with Plex, Jellyfin, and Emby.
- [x] The public support URL and privacy-policy URL resolve over HTTPS:
      [Support](https://jlipworth.github.io/Labstream/support/) and
      [Privacy](https://jlipworth.github.io/Labstream/privacy/).
- [ ] Replace the staged single-image synthetic placeholders with final, reviewed
      screenshot sets for every required App Store device size;
      the Vision Pro set includes at least one 3840 × 2160 image. Apple permits up to ten
      screenshots and up to three optional app previews per supported size and localization. See
      Apple's current
      [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
      before capture because requirements can change.
- [ ] Final screenshots show only licensed demo media and contain no account, server, network, or
      personal information. At minimum, cover Home, library browsing, a title detail surface, and
      playback; add Downloads only on platforms that ship it and platform-specific features only
      where they are actually available.
- [ ] Screenshot automation can reproduce the accepted set from clean fixture/review state for
      iPhone, iPad, Mac, Apple TV, and Apple Vision Pro, and the exported files pass the repository
      size/privacy manifest validator before upload.
- [ ] App Privacy: the shared label is published with seven data types linked to the user and
      tracking off; the earlier **Data Not Collected** answer is superseded. Still open: verify
      received support storage outside GitHub and end-to-end demo database/log/edge/backup
      retention against the published answers
      ([#325](https://github.com/jlipworth/Labstream/issues/325) is closed, but its closure does
      not resolve these). See the [bounded privacy audit](https://github.com/jlipworth/Labstream/blob/main/docs/evidence/audits/2026-09-16-review-service-privacy-audit.md) for
      the data-type mapping and owner approval gates. No App Store Connect answer is changed
      by documentation edits. Required-reason API declarations are a separate packaging check
      ([#326](https://github.com/jlipworth/Labstream/issues/326)), not a collection exemption.
- [ ] Verify export-compliance answers against the exact candidate and linked dependencies.
      `ITSAppUsesNonExemptEncryption` remains false in source; this is not a new binary/account
      certification.
- [ ] Evaluate any storefront accessibility feature claims on each submitted platform against
      Apple's criteria; source labels and passing tests alone do not establish support.

- [x] Inspect app/dependency privacy manifests and the Xcode aggregate privacy report from
      each exact signed Release archive (visionOS, iOS/iPadOS, tvOS, macOS). Confirm the
      SystemBootTime `35F9.1` declaration and its actual-use restrictions; unsigned/source
      checks do not close this gate. See [packaging verification](DEVELOPMENT.md#required-reason-privacy-manifest-packaging)
      and [issue #326](https://github.com/jlipworth/Labstream/issues/326).

### TestFlight and App Review

- [x] The recorded TestFlight beta description, feedback contact, and **What to Test** text are
      current. Internal builds remain available for 90 days; Apple currently permits up to 100 internal App Store
      Connect users. See the current [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview).
- [x] Review contact information is complete in App Store Connect. Do not commit it here.
- [ ] Because the app requires sign-in, App Review has a stable, non-expiring demo path and clear
      steps for choosing a backend, signing in, browsing a library, and playing authorized sample
      media. Store credentials only in App Store Connect, never in Git or issue comments.
- [ ] The review environment is reachable from Apple networks without a VPN or private DNS, uses
      non-personal sample media that may be shown to reviewers, and is tested from a fresh install
      on every submitted platform. If a community demo service is used, verify its current terms,
      stability, credentials, and permission for App Review before depending on it.
- [ ] Do not enable public availability, add a platform version for review, or submit the app until
      the licensed-media manifest, final screenshot sets, and clean-install reviewer journey above
      have been accepted.
- [ ] Review notes explain local-network access, direct connections to user-selected servers,
      optional offline downloads, the absence of bundled media, and where Cinema mode is found.
- [ ] Review notes call out platform differences: one iOS binary serves iPhone and iPad; tvOS has
      no downloads/offline surface; Cinema is visionOS-only; and macOS uses a sandboxed native app.
- [x] The correct build is attached to each platform version before **Add for Review** and the final
      **Submit for Review** action. See Apple's current
      [submission procedure](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).

### Account-holder and legal gates

These gates cannot be completed by source changes or automation:

- [x] The Account Holder reviews and accepts any current Apple Developer Program agreement.
- [ ] Trader status is declared. Apple requires a declaration even when an app is not offered in
      the EU; EU distribution by a trader requires verified public contact information. See
      Apple's [EU Digital Services Act guidance](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/).
- [ ] Agreements, tax, banking, pricing, territories, and release method are configured as required
      for the selected business model and storefronts.
- [ ] The Account Holder explicitly approves the final storefront scope and submission.

## Public-release closeout

After approval, verify the live product page and its support/privacy links, publish the exact
corresponding source and release notes, create the authorized annotated tag, and record the
released platform/version in this page. Do not describe an internal TestFlight build as a public
App Store release.

## After launch: monitoring

`scripts/asc-digest.py` is a read-only daily digest for the maintainer: new customer reviews (with
platform where App Store Connect attributes it), Xcode Organizer diagnostic signatures (hangs, disk
writes, launches) for the newest builds of the current marketing version on each platform, and
TestFlight crash and screenshot feedback. It reuses the `testflight-release.py` credentials, issues
only `GET` requests, and writes `digest.md`/`digest.json` to the gitignored
`artifacts/asc-digest/<date>/`; stdout carries counts only. A state file there limits each run to
items not seen before (`--all` ignores it; `--since 7d` widens the window). `--logs` and
`--attachments` save diagnostic/crash logs and feedback screenshots to the same private directory.
Review text, nicknames, tester emails, and logs are personal data: never paste them into issues,
commits, or public docs. Endpoints that return 403/404 (common before the app is public) are listed
as unavailable rather than failing the run. See [Scripts](SCRIPTS.md).
