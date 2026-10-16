# Review-service privacy audit — 2026-09-16

## Scope and status

Follow-up to [#325](https://github.com/jlipworth/Labstream/issues/325),
[#280](https://github.com/jlipworth/Labstream/issues/280), and
[#92](https://github.com/jlipworth/Labstream/issues/92). App source baseline: `e9344f63`.
Read-only inspection covered the dedicated service's private deployment source, rendered live
configuration, resource status, filesystem metadata, and bounded schema/log-pattern checks.
No secret values, user rows, request bodies, raw logs or catalog details are published here.
No service setting, credential, account answer, reset, playback, transcode, or deployment was changed.
This is not legal certification or permission to submit a release. #325 remains open.

Private source provenance: infrastructure checkout `d18301ff8370e22b434a9d912af0130c22575eff`,
review-service runbook, deployment, logging configuration, bootstrap/reset code, proxy routing,
RBAC/network policies, centralized logging values, recurring storage jobs and backup values.
The checkout was clean. Source intent and live evidence are distinguished below; neither a runbook
claim nor an enabled schedule proves deletion from every copy.

## Findings

| Surface | Verified evidence | Limit / disposition |
| --- | --- | --- |
| Ordinary app traffic | `JellyfinAuth.swift` sends account authentication plus app/device identity; `JellyfinPlayback.swift` and the MediaBrowser progress plan send playing/progress/stopped operations to the selected server. Normal Plex/Emby flows likewise use selected backend services. | No automatic app diagnostic upload was identified. That is not absence of server-side collection when the project operates the selected server. |
| Dedicated review service | Live deployment ready; public-path smoke last succeeded on the audit date. The reviewed source implements non-admin review policy, hidden/local-only admin, read-only media and network isolation. | Existing #280 infrastructure success does not close exact TestFlight reviewer acceptance. No playback was run in this audit. |
| Auth, activity and state | Persistent Jellyfin database is present. Bounded schema inspection confirms Devices (account, token, app/device identity/version, activity dates), ActivityLogs (account/item references, descriptions, timestamps), and UserData tables. | Database row counts/ages and token/session expiry were not queried: the server container lacks SQLite/Python/Perl DBI tooling, while the Python controller has no database mount. No database copy, tool installation or new authenticated session was made. Schema is not proof that every possible field is populated. Owner must verify aggregate record ages, deletion tasks and effective expiry privately. |
| Reset | Source clears playback position, play count, favorite, likes, last-played and played state for the bounded catalog query. Daily schedule; last successful reset observed on the preceding day. | It does not erase device/auth/activity records, logs, backups or every preference. No reset invoked. Prior #280 favorite-reset success is historical, not a new deletion test. |
| Reverse proxy | Live generated route has access logs disabled; metrics enabled and minimal trace verbosity. | Does not establish no logging at other proxy layers, tracing/metrics sinks or the public edge provider. Provider record types, access and retention remain unverified. |
| Jellyfin diagnostic files | Live Warning minimum, console output, daily file rotation, 10,000,000-byte roll limit and 3 retained files match source. Three small files observed covering the preceding three days. Bounded pattern counts found no URL/token-key-like strings in these files. | Neither absence of those patterns nor Warning level proves all future messages are free of personal data. Three files is a count/size policy, not a three-day universal deletion promise. No raw messages exported. |
| Central logs | Pod stdout is routed by the configured cluster collector to Loki; rendered live Loki config declares 30-day retention. | No explicit enabled retention compactor found in rendered config. Effective deletion and oldest retained review-service entries were not verified. Do not advertise a 30-day deletion guarantee. |
| Backups | Config volume participates in the default storage backup group. Live recurring jobs retain 240 six-hour backups and 16 six-hour snapshots; config-volume status reports a recent backup on the audit date. | These are copy-count settings, not proven maximum age. Source also describes daily Velero filesystem backups with 30-day TTL, but live Velero schedules were empty. Investigate this mismatch, actual backup inventories, downstream replicas and deletion enforcement before promising expiry. No backup restored or altered. |
| Access | Review account is designed to be non-admin. Namespace service accounts are scoped; edge Role grants certificate/route operations, not secret reads. Jellyfin has no mounted service-account token. | Infrastructure operators with cluster/storage rights can access records and backups. Loki rendered config has tenant authentication disabled; network/administrative boundaries matter. Full operator/group membership, edge-provider access and backup-reader inventory were not certified. |

## Optional feedback: all conditions, not just consent

Apple's current [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
defines collection to include developer/partner access beyond real-time servicing. Functionality-only
use can still require disclosure. Optional disclosure requires **all** of these conditions:

| Apple condition (paraphrased) | Current evidence / result |
| --- | --- |
| No tracking | No tracking integration identified in the reviewed app path; policy prohibits it. |
| No advertising, marketing or other-purpose use | Intended use is support/troubleshooting. Owner must confirm actual handling of received reports. |
| Infrequent, optional, outside primary functionality | Feedback is optional support, not playback; no automatic upload loop. Confirm actual collection remains infrequent. |
| In-app provision; clear contents; prominent user/account name beside submitted data; affirmative choice every time | `FeedbackSheet.swift` previews the report/note and requires an action, but does **not** prominently display the submitting user's GitHub/account name. External GitHub identity display is not proof of this entire in-app condition. Export/share destinations differ. **Exemption not established.** |

Copy/local export alone is not developer receipt. GitHub URL prefill transmits included fields to
GitHub on opening, before public issue submission; long reports fall back to clipboard/plain form.
Public submissions associate content with a GitHub account. These distinctions are now explicit in
the policy. The manifest's empty collection array cannot certify a storefront answer. Optional demo
use likewise is not automatically exempt: it serves the app's primary media functionality.

## Proposed mapping — owner review required, not account edits

Use the current Apple taxonomy and verify actual candidate/provider behavior before selecting answers:

| Observed or possible collection path | Proposed review items | Intended purpose / linkage review |
| --- | --- | --- |
| Demo authentication/device records | User ID, Device ID | App Functionality; account/device association means do not assume unlinked merely because the account is shared or fictional. |
| Demo viewing/progress/activity | Product Interaction; evaluate Other Usage Data for additional retained operations | App Functionality; assess Product Personalization if retained state customizes recommendations/resume. No advertising/tracking use identified. |
| Retained operational failures/network information | Other Diagnostic Data; Performance Data if actually retained | App Functionality/security. Classify IP addresses by actual use, not automatically as location. Verify edge processing and linkage. |
| Submitted support report, note and account | Customer Support, User ID; evaluate included diagnostics/Crash Data/Performance Data | App Functionality/support; no optional-disclosure exemption certified. Confirm all report variants and actual receipt/storage. |
| Purely local report, downloads and preferences | No off-device developer collection solely from local storage | Reassess separately when shared or synchronized to a project-operated service. |

This is a proposed inventory, not a final label or manifest patch. In particular, do not select
Search History, location or other speculative categories without evidence of retained data/use.
No App Store Connect answers were read or changed. Required-reason APIs (including #326) are separate
from collected-data declarations.

## Remaining approval and evidence gates

1. Infrastructure owner: verify auth/device/activity/progress aggregate ages and effective cleanup;
   distinguish logical reset from deletion and backups. Establish an honest retention policy before
   publishing a fixed maximum; do not retrofit a claim from current file counts.
2. Verify centralized-log deletion enforcement, all edge/proxy/tracing sinks, provider retention,
   backup inventories/downstream copies and the Velero discrepancy; confirm privileged access lists.
3. Owner: confirm purposes and handling of received support reports, retained attachments and GitHub
   history. Either disclose applicable support data or demonstrate every optional-disclosure condition
   for each shipped handoff. A future UI fix would require separate scoped implementation/testing.
4. Freeze the candidate, inspect compiled manifests and all integrated SDKs for every archive, then
   reconcile proposed collection/purpose/linkage answers with the account's current answers. Obtain
   explicit approval for any manifest/account declaration changes; do not reuse the historical
   **Data Not Collected** certification.
5. Review and publish the corrected policy/support wording before submission. Keep #280's physical
   TestFlight/reviewer gate open. This audit does not resolve account/legal declarations or authorize
   upload, release, version changes, or service configuration changes.
