# Release and App Store status

This page is the public source of truth for Labstream's distribution status and the release
checks that can safely live in the repository. It does not contain signing identities, App Store
Connect contact details, review credentials, tokens, private server addresses, or other secrets.

## Current status

| Product | Source version | Distribution status |
| --- | --- | --- |
| Apple Vision Pro (`Labstream`) | 1.6.1 (build 1) | Primary release path. An earlier 1.6.0 (build 1) binary is available to the private internal TestFlight group; 1.6.1 has not been uploaded. |
| iPhone and iPad (`LabstreamMobile`) | 1.6.1 (build 1) | Supported local and signed-device development path; no public App Store or TestFlight release. |
| Apple TV (`LabstreamTV`) | 1.6.1 (build 1) | Streaming-only development target; not a released or supported App Store product. |
| Mac (`LabstreamMac`) | 1.6.1 (build 1) | Local-build development preview; not a released or supported App Store product. |

The four targets share a coordinated 1.6.1 codebase milestone, but version synchronization does
not make every target a distribution candidate. The Xcode project remains the source of truth.

`1.6.1` is the user-facing marketing version (`CFBundleShortVersionString`). The number in
parentheses is the App Store build number (`CFBundleVersion`). A new marketing version begins at
build 1; each replacement upload for the same platform and marketing version must use a higher
build number.

## Vision Pro release checklist

### Repository and binary

- [ ] The release commit contains no credentials, private endpoints, signing files, diagnostic
      bundles, or personal media data, including in newly added files.
- [ ] `PMSKit` hermetic tests, repository hygiene, strict MkDocs, and the affected native test
      matrix pass.
- [ ] A clean Release archive is produced with the intended Xcode release and Apple Distribution
      signing; the archive reports the expected marketing version and build number.
- [ ] The archive passes Xcode validation and App Store Connect processing without compliance or
      binary warnings.
- [ ] The selected App Store Connect build metadata reports the intended minimum OS, device
      family, entitlements, and supported architecture.
- [ ] A physical Vision Pro TestFlight smoke covers first launch, sign-in, browse, playback,
      seeking, subtitles, audio, Cinema, background/foreground, and diagnostics. Simulator smoke
      is useful but does not replace this gate.
- [ ] The release commit is publicly available as corresponding GPLv3 source. Create the annotated
      coordinated tag `vX.Y.Z` only after the version commit exists and tagging is authorized.

### Product-page metadata

- [ ] App name, subtitle, category, age rating, description, keywords, copyright, and availability
      are complete and match the product that was tested.
- [ ] The description states that Labstream connects to a server selected by the user, provides no
      media, and is unofficial and unaffiliated with Plex, Jellyfin, and Emby.
- [ ] The public support URL and privacy-policy URL resolve over HTTPS:
      [Support](https://jlipworth.github.io/Labstream/support/) and
      [Privacy](https://jlipworth.github.io/Labstream/privacy/).
- [ ] At least one Apple Vision Pro screenshot is supplied at 3840 × 2160 pixels. Apple permits up
      to ten screenshots and up to three optional landscape app previews per supported size and
      localization. See Apple's current
      [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
      before capture because requirements can change.
- [ ] Screenshots show only authorized media and contain no account, server, network, or personal
      information.
- [ ] App Privacy answers match the shipped privacy manifest and runtime behavior. The current
      intended answer is **Data Not Collected**: Labstream has no developer analytics, tracking,
      telemetry upload, or developer-operated backend. Re-audit this if dependencies or behavior
      change.
- [ ] Export-compliance answers match the binary. `ITSAppUsesNonExemptEncryption` is currently
      false; re-evaluate if cryptography use changes.

### TestFlight and App Review

- [ ] TestFlight beta description, feedback contact, and **What to Test** text are current. Internal
      builds remain available for 90 days; Apple currently permits up to 100 internal App Store
      Connect users. See the current [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview).
- [ ] Review contact information is complete in App Store Connect. Do not commit it here.
- [ ] Because the app requires sign-in, App Review has a stable, non-expiring demo path and clear
      steps for choosing a backend, signing in, browsing a library, and playing authorized sample
      media. Store credentials only in App Store Connect, never in Git or issue comments.
- [ ] Review notes explain local-network access, direct connections to user-selected servers,
      optional offline downloads, the absence of bundled media, and where Cinema mode is found.
- [ ] The correct build is attached to the platform version before **Add for Review** and the final
      **Submit for Review** action. See Apple's current
      [submission procedure](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).

### Account-holder and legal gates

These gates cannot be completed by source changes or automation:

- [ ] The Account Holder reviews and accepts any current Apple Developer Program agreement.
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
