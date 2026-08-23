# Release and App Store status

This page is the public source of truth for Labstream's distribution status and the release
checks that can safely live in the repository. It does not contain signing identities, App Store
Connect contact details, review credentials, tokens, private server addresses, or other secrets.

## Current status

| Product | Source version | Distribution status |
| --- | --- | --- |
| Apple Vision Pro (`Labstream`) | 1.6.1 (build 1) | Clean `20bea2546dd1` archive uploaded and processed; selected for the platform version and available to the internal TestFlight group. Physical TestFlight acceptance and review access remain pending. |
| iPhone and iPad (`LabstreamMobile`) | 1.6.1 (build 1) | Clean `20bea2546dd1` universal iOS archive uploaded and processed; selected for the platform version and available to the internal TestFlight group. Physical iPhone and iPad acceptance remain pending. |
| Apple TV (`LabstreamTV`) | 1.6.1 (build 1) | Clean `20bea2546dd1` archive uploaded and processed; selected for the platform version and available to the internal TestFlight group. Physical Apple TV acceptance remains pending. |
| Mac (`LabstreamMac`) | 1.6.1 (build 1) | Clean `20bea2546dd1` archive uploaded and processed; selected for the platform version and installed from TestFlight on a Mac. Deeper sandbox and live-host acceptance remain pending. |

The four targets share the neutral `org.labstream.Labstream` bundle identifier and are intended
for one App Store Connect universal-purchase record. The earlier private visionOS 1.6.0 build used
a retired personal-namespace identifier; it is not the publication record for 1.6.1 and cannot be
migrated because Apple freezes a record's bundle identifier after its first build upload.

The publication topology is one product record with four platform versions and four binary
archives: the `LabstreamMobile` iOS archive covers both iPhone and iPad, while visionOS, tvOS, and
macOS each use their own archive. Metadata, screenshots, build selection, review notes, and
acceptance remain platform-specific even when the platforms share one purchase record. A platform
must not be marked ready merely because another platform passed review.

App Store Connect currently has the shared app information, free price schedule, published
**Data Not Collected** privacy answer, platform descriptions, review contacts, build selections,
manual-release settings, and one privacy-safe synthetic placeholder screenshot for each submitted
device family. Those screenshots prove the capture and upload path, but they are not the intended
public product-page set. App availability is not yet enabled. Licensed demo media, final screenshot
capture and review, demo review access, review notes, physical-platform acceptance, storefront
scope, Digital Services Act status where applicable, and final submission remain open.

`1.6.1` is the user-facing marketing version (`CFBundleShortVersionString`). The number in
parentheses is the App Store build number (`CFBundleVersion`). A new marketing version begins at
build 1; each replacement upload for the same platform and marketing version must use a higher
build number.

## Initial publication sequence

The first neutral-identity deployment should proceed in this order:

1. In the Apple Developer account, confirm the neutral App ID and required capabilities, then make
   an Apple Distribution signing identity and platform-appropriate App Store provisioning available
   to Xcode. Do not commit certificates, private keys, profiles, account identifiers, or exports.
2. Create the new App Store Connect app for `org.labstream.Labstream`, then add the visionOS,
   iOS/iPadOS, tvOS, and macOS platform versions to that one universal-purchase record. Do not reuse
   the retired personal-identity visionOS record.
3. From the exact public release commit, produce and locally validate one archive each for
   `Labstream`, `LabstreamMobile`, `LabstreamTV`, and `LabstreamMac`. Confirm identity, version,
   build, entitlements, minimum OS, architecture, and device family before upload.
4. Upload each archive and wait for App Store Connect processing. Treat warnings or missing
   platform associations as blockers; do not advance a different binary merely because it shares
   the version number.
5. Establish the reviewer environment and its licensed sample-media inventory, then capture and
   privacy-review the final platform-specific screenshot sets. Complete shared app information plus
   platform metadata, build selection, privacy/export answers, review notes, and review access.
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

The official stable demo is the first evaluation lane before provisioning new infrastructure. It
currently exposes a passwordless shared account, Quick Connect, Movies/Shows/Music/Playlists, and a
catalog containing public/open test media. It is useful for compatibility and screenshot trials,
but it is not yet accepted as the final reviewer dependency: the shared account is mutable,
downloads are disabled, service resets can interrupt sessions, and the project's permission for
third-party App Store marketing screenshots still needs to be established. Labstream supports the
demo's passwordless Jellyfin login as of
[issue #283](https://github.com/jlipworth/Labstream/issues/283).

Prefer a Labstream-controlled review instance with a deterministic catalog of original,
public-domain, or appropriately Creative Commons media. Record every title, artwork source,
license, attribution requirement, and permitted screenshot/review use in a repository manifest;
do not use commercial movie or television artwork merely because a metadata provider can return
it. The same catalog should drive automated screenshots and the reviewer journey so the captured
UI matches the environment Apple can actually test.

## Apple-platform release checklist

### Repository and binary

- [ ] The release commit contains no credentials, private endpoints, signing files, diagnostic
      bundles, or personal media data, including in newly added files.
- [ ] `PMSKit` hermetic tests, repository hygiene, strict MkDocs, and the affected native test
      matrix pass.
- [x] Clean Release archives are produced for iOS/iPadOS, visionOS, tvOS, and macOS with the
      intended Xcode release and Apple Distribution signing; every archive reports the neutral
      bundle identifier and expected marketing version and build number.
- [x] Archives are reproducible from the exact public release commit. If that commit changes after
      a preflight archive, rebuild rather than treating the older archive as the submission binary.
- [x] Every platform archive passes Xcode validation and App Store Connect processing without
      compliance or binary warnings.
- [x] Each selected App Store Connect build reports the intended minimum OS, device family,
      entitlements, and supported architecture.
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
- [ ] Replace the currently staged single-image synthetic placeholders with final, reviewed
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
- [x] App Privacy answers match the shipped privacy manifest and runtime behavior. The current
      intended answer is **Data Not Collected**: Labstream has no developer analytics, tracking,
      telemetry upload, or developer-operated backend. Re-audit this if dependencies or behavior
      change.
- [x] Export-compliance answers match the binary. `ITSAppUsesNonExemptEncryption` is currently
      false; re-evaluate if cryptography use changes.

### TestFlight and App Review

- [x] TestFlight beta description, feedback contact, and **What to Test** text are current. Internal
      builds remain available for 90 days; Apple currently permits up to 100 internal App Store
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
