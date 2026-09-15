# Pre-release disclosure audit — 2026-09-15

Scope: read-only source audit at merged `e9344f63`, public support/privacy reachability,
release tracking, and review of screenshot branch `7f93e1ee`. This is not a fresh App Store
Connect query, legal certification, signed-archive inspection, or platform acceptance run.
No account answers, runtime code, privacy manifest, server configuration, or release settings
were changed by this audit. Follow-up fixes remain separate.

## Findings and disposition

| Area | Source evidence | Disposition |
| --- | --- | --- |
| Required-reason APIs | `PrivacyInfo.xcprivacy` declares UserDefaults, FileTimestamp and DiskSpace, but production `PlaybackController` and `PlaybackDiagnostics` use `systemUptime`. | Missing SystemBootTime declaration: [#326](https://github.com/jlipworth/Labstream/issues/326). Audit uses/egress and inspect all final archive manifests. |
| Developer-operated services | `PRIVACY.md` says no developer-operated backend; dedicated review/demo infrastructure is tracked in #280. | Reconcile the absolute claim and actual service retention: [#325](https://github.com/jlipworth/Labstream/issues/325). Do not invent retention or silently certify Data Not Collected. |
| Optional feedback | Policy describes user-initiated redacted GitHub/report exports. | Check all optional-disclosure conditions, not user initiation alone, in #325. |
| Permission descriptions | Shared plist names Plex/Jellyfin/Emby and browse/play/download; tvOS plist separately omits download. Both declare scoped local networking, not arbitrary-load ATS. | Source wording matches platform feature scope; final compiled plist and real permission UX still require acceptance. |
| Export answer | Both app plists set non-exempt encryption false. Source uses Apple networking and CryptoKit SHA-256; PMSKit pins swift-crypto with swift-asn1 resolved. | No flag change in this audit. Inspect actual linked Release dependencies and reconcile the existing answer; a source search is not export certification. |
| Public links | HTTPS support and privacy endpoints both returned HTTP 200. | Reachability checked; this does not establish policy completeness. |
| Accessibility | Source/test coverage is not a completed platform-specific accessibility evaluation. | Keep storefront feature claims unapproved until evaluated against the exact candidate. |
| Source versus distribution | Main is 1.7.1 build 1; latest recorded processed set is 1.6.1 build 2. | Preserve this distinction; do not mark current binary gates complete from historical checks. |

Apple lists `systemUptime` under SystemBootTime. Reason 35F9.1 covers in-app elapsed-time/timer
uses with restrictions on off-device information; inspect the actual use before selecting it.
See [required-reason API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

Apple's [privacy guidance](https://developer.apple.com/app-store/app-privacy-details/) requires
current answers covering applicable collection, including functionality-only uses. Optional
support disclosures must satisfy all listed conditions. The empty collection array in the
manifest does not independently establish a correct storefront privacy label.

Use Apple's [accessibility evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/)
for each submitted platform; no accessibility support claim was approved by this audit.

## Screenshot branch review

Reviewed `7f93e1ee` on `codex/store-demo-provenance`; no merge performed. Its changes separate
synthetic fixture/layout images from real final captures, document licensed media and derivative
artwork provenance, and retain review/attribution and age-suitability gates. Nine screenshot
tooling tests passed during this review. This is a documentation/tooling review, not fresh live
catalog hash verification or legal clearance of every eventual screenshot.

The plan correctly retains the large-iPhone and large-iPad requirements instead of treating any
accepted image dimensions as sufficient coverage. The existing exporter validates dimensions,
not completeness of required display classes. Confirm final sets against Apple's
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
Actual captures, normal review-account login, attribution presentation, editorial age-rating
review and exact TestFlight journeys remain outstanding. Do not equate openly licensed media
with automatic suitability for a 4+ presentation.

## Release tracking

- #259 is explicitly deferred by the user; it remains open and unvalidated. Deferral is not a
  disconnected cold-launch pass or a promise of reliable offline cold launch.
- #280 has bounded infrastructure evidence, but exact-candidate app/reviewer acceptance remains open.
- Playback investigations #288, #291, #303, #305, #322, #323 and #324 are not blanket-closed by
  merged implementation work, isolated successful runs, or this audit.
- #325 and #326 require resolution before certifying current privacy disclosures/packaging.
- App Store Connect versions, agreements, trader status, export answers and accessibility labels
  were not queried or modified; those remain a separate read-only account audit and approval gate.
