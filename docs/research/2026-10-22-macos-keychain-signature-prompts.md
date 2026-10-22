# macOS keychain signature-switch investigation (#343)

Status: investigation only, 2026-10-22. No production credentials accessed and no
storage behavior changed. Base: `downloads/overhaul` at
`e2e4c3b810eafba24f0b95fa7b68e26d9264ee64` (the supplied integration branch,
not main). [Issue #343](https://github.com/jlipworth/Labstream/issues/343) body and
complete comments collection were read through `gh issue view`; there were zero
comments at investigation time. Its reproduction is user-reported, not reproduced here.

## Conclusion and scope

The legacy-keychain explanation is strongly supported by source and Apple documentation.
Move canonical macOS local items to the data-protection keychain, but **do not ship a
blanket selector change plus read/copy/delete loop**. First preserve read failures as
typed outcomes throughout restoration, identifier creation, migration, and rollback.
Retain readable old logins until a new copy and migration marker are verified. Stop
background legacy access, including cleanup, when consent would be required.

Implementation of error classification and hermetic test seams can proceed without a
product decision. Shipping automatic migration cannot: approve the recovery/consent UX,
stale-token policy, and supported downgrade boundary first. Neither forced re-login nor
loss of the device identifier is an acceptable silent default for this investigation.

Read-only scope included `KeychainStore`, `AppRuntime`, `AuthManager`, both Mac
entitlement templates, project signing settings, host-deploy and TestFlight scripts,
existing credential tests, and current [persistence](../PERSISTENCE.md#keychain),
[Mac](../MACOS.md), [development](../DEVELOPMENT.md), and
[testing](../TESTING-STRATEGY.md) guidance. No host app launch, simulator boot, signing
credential lookup, production item enumeration, value read, reset, or migration was run.

## Verified source findings

| Area | Current behavior at the base revision |
| --- | --- |
| Query identity | `baseQuery` uses generic-password class, service, account; it adds synchronizable=true only for the canonical Plex `token`. It never sets `kSecUseDataProtectionKeychain`, access group, or authentication UI policy. |
| Plex token | Synchronizable primary read; when no value is decoded, a non-synchronizable legacy read occurs even if primary failed. A legacy value is returned even if promotion fails. Successful primary read/save attempts legacy deletion every time; delete errors are ignored. |
| Local accounts | `clientIdentifier`, `selectedBackend`, `selectedPlexServerID`, and four fields each for Jellyfin/Emby: server URL, access token, user ID, server ID. These remain non-synchronizable. On native macOS the default queries target file-based storage. |
| Write | Update first; add only on `errSecItemNotFound`. Adds request `kSecAttrAccessibleAfterFirstUnlock`; supplying accessibility alone does not select the Mac data-protection implementation. |
| Read errors | `readItem` retains OSStatus internally, but public `read` collapses absence, denied/unavailable access, and malformed data to nil. Even success with non-UTF-8 data becomes nil. Non-sync failures do not perform Plex legacy fallback, but callers can still default or write. |
| Identifier and selection | `clientIdentifier()` generates and saves on any nil read. `AppRuntime` uses a process-local UUID if this fails; `selectedBackend` defaults to Plex on nil. A transient storage error can therefore change runtime identity or selection. |
| Multi-field rollback | `saveCredentialSet` snapshots using optional reads. If a prior value was unreadable, rollback treats it as absent and attempts deletion. This is a potential data-loss path, not a reproduced loss. |
| Delete/sign-out | Token delete uses synchronizable-any without a data-protection selector; other deletes use local query. Fallback-file cleanup occurs even if Security deletion fails. A future selector would also change which legacy copies these calls can reach. |

Relevant call sites: `Labstream/Shared/Auth/KeychainStore.swift` (`baseQuery`, `read`,
`readItem`, `saveToKeychain`, `delete`, `saveCredentialSet`, `clientIdentifier`),
`Labstream/Shared/App/AppRuntime.swift` (`make`, `AppKeychainService`), and
`Labstream/Shared/Auth/AuthManager.swift` (restore helpers, credential snapshots,
sign-out). Existing restore outcome types do not repair the lost Security status.

### Signatures and identities

Both Debug and Release Mac targets use bundle/service `org.labstream.Labstream` and
`Config/LabstreamMac.entitlements`, whose group template is
`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`. No explicit group is set in
KeychainStore; the effective default group matters. The host wrapper's intentional
production mode uses Apple Development signing and provisioning. TestFlight tooling
archives Release with a selected distribution identity/profile. Source templates are
**not proof** that the actual distributed and development products have identical,
authorized groups; inspect signed artifacts and their profiles without launching them.
Do not assume AppIdentifierPrefix always equals Team ID.

The default host wrapper instead chooses a per-worktree bundle/service and development
entitlements without a keychain group. `AppRuntime` selects isolated credential files
only for noncanonical Mac Debug/PerformanceAudit builds; Release cannot opt in.
These development builds cannot validate production keychain sharing. Keep this exception.
No release/preflight command was run: it can consult real signing/API credentials.

## Apple evidence and limits

Sources checked on 2026-10-22, including Apple's Markdown endpoints where the HTML
required JavaScript:

1. [TN3137 — Choosing the right keychain / Implementation differences](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains):
   native Mac SecItem can target file-based or data-protection storage. File-based
   access uses ACLs, while data protection uses entitled access groups and requires a
   user login context. File-based reads consult the search list; adds use the default
   keychain. Thus “login keychain” is the usual case, not proof of the actual location.
2. [kSecUseDataProtectionKeychain — Discussion](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain):
   true selects iOS-style storage on Mac, including for local items; it is ignored on
   other platforms. Apple recommends it except when accessing existing legacy items.
   This supports an explicit legacy adapter, not overwriting the selector everywhere.
3. [kSecAttrSynchronizable — Discussion](https://developer.apple.com/documentation/security/ksecattrsynchronizable):
   true already selects iOS-style access and requests sync; false/omitted excludes
   synced results; any matches both sync states. Synchronized changes affect remote
   copies. **tvOS does not sync items through iCloud**, despite accepting the attribute.
   Keep local backend tokens/identifiers unsynchronized; do not use sync as a workaround.
4. [Sharing access — Set your app's access groups / Set a keychain item's access group](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps):
   group membership derives from signed entitlements; default creation uses the first
   group, while unqualified searches cover available groups. Same team alone is
   insufficient. A wrongly scoped search can report not-found; validate identity before
   interpreting absence as permission to generate or migrate.
5. [TN3127 — Designated requirement / Mutually compatible designated requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements):
   explicitly discusses unexpected keychain authorization alerts with TestFlight and
   explains channel-dependent designated requirements. This corroborates the theory,
   but does not prove these two installed builds' requirements or item ACLs. An exact
   signature hash change is not itself proof of incompatible requirements. No evidence
   here establishes that Always Allow necessarily revokes a previous grant or that one
   final round of migration prompts is guaranteed.
6. [kSecUseAuthenticationUI](https://developer.apple.com/documentation/security/ksecuseauthenticationui)
   defaults to allowing UI; [kSecUseAuthenticationUIFail](https://developer.apple.com/documentation/security/ksecuseauthenticationuifail)
   returns interaction-not-allowed when authentication is needed. The installed SDK
   marks the latter deprecated in favor of
   [kSecUseAuthenticationContext](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext)
   with [LAContext.interactionNotAllowed](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed).
   Do not assume LocalAuthentication suppresses every legacy ACL dialog without testing.
   [SecKeychainSetUserInteractionAllowed](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:))
   controls legacy UI but affects other clients; any necessary compatibility wrapper
   must serialize access and restore the prior setting, including on error.
7. [errSecAuthFailed](https://developer.apple.com/documentation/security/errsecauthfailed),
   [errSecInteractionNotAllowed](https://developer.apple.com/documentation/security/errsecinteractionnotallowed),
   and [errSecItemNotFound](https://developer.apple.com/documentation/security/errsecitemnotfound)
   describe distinct outcomes. Only the last represents no match in the queried domain;
   none grants permission to erase another domain.

## Proposed minimal safe migration

1. **Typed storage and bounded access.** Return `found(value)`, `absent`,
   `unavailable(status)`, or `invalidData`, retaining the queried domain. Treat auth
   failure, user cancellation, interaction-not-allowed/required, missing entitlement,
   unavailable service, and unknown errors as non-absence. No fallback, generation,
   deletion, or rollback-from-nil after such a result. Validate signed group configuration
   before allowing absence-driven writes. Preserve credentials on restore failure;
   show storage recovery, not “no login.” Keep any process-only identifier away from
   authenticated device-bound sessions until the durable identifier is recovered.
2. **Explicit domains.** Centralize data-protection queries for every canonical Mac
   read/add/update/delete, with false sync for local items and true only for Plex token.
   Preserve the existing intended access group and accessibility policy. A separate
   legacy adapter uses false/omitted data protection and non-sync matching, scoped by
   exact service/account/class. Never use broad keychain enumeration or delete-all.
   Do not change other platforms' storage policy or Mac development-file routing.
3. **No automatic prompt loop.** Serialize migration and cache unavailable outcomes
   for the current attempt. Background restore, scene creation, and retries must not
   start legacy UI or repeatedly clean up old items. First try strictly noninteractive
   access. When consent is necessary, offer one foreground recovery action and stop
   the entire attempt on denial/cancel. Retry only on a new explicit action or relevant
   availability change. Do not promise one OS prompt: ACLs are per item.
4. **Copy, verify, then commit authority.** Prefer a valid new item; when both exist,
   never overwrite it with the old value. For an eligible old-only account, read it
   once, add the new item, read back and compare in memory, then persist a versioned,
   non-secret data-protection migration marker. Re-read on duplicate-add races; do not
   blindly update. Keep source on any error. For Jellyfin/Emby, migrate the durable
   client identifier and complete backend credential set as a unit with a commit
   marker; readers ignore an uncommitted partial set. Preflight every old snapshot
   before writing, resume idempotently after crashes, and never expose mixed old/new
   fields. Optional server ID may be genuinely absent; required missing fields need
   recovery, not fabricated values. No markers contain tokens, URLs, user/server IDs,
   or credential hashes.
5. **Retire fallback before deleting source.** A committed marker means legacy is
   permanently ineligible for restoration, even when new data later disappears.
   Recognizing an existing synchronized Plex token must establish this rule without
   legacy reads/deletes on each access. Keep legacy copies initially for recovery;
   cleanup is separate, explicit, bounded, and never a prerequisite for new reads.
   Storage being unavailable is not a reason to fall back to a retained old copy.
6. **Sign-out/revocation are durable transitions.** Mark legacy ineligible before
   deleting authoritative data. Abort and report failure if this cannot be persisted.
   Clear runtime authorization and block stale in-flight writes; report pending cleanup
   rather than successful durable sign-out if a deletion fails. Delete only targeted
   backend accounts (retain the device identifier); Plex sync deletion retains its
   cross-device meaning. Cleanup failures cannot re-enable fallback. Remote deletion
   after observing Plex primary must never re-promote local token. A remote update wins
   over a stale candidate; serialize and recheck primary before commit, acknowledging
   that iCloud is not an atomic cross-device compare-and-swap transaction.

**Unavoidable ambiguity:** with no primary and no local observation/retirement marker,
an old token may be either a valid pre-sync login or a stale copy after a remote sign-out.
An absent local query cannot distinguish them. Safest default: explicit user-authorized
recovery/re-authentication before promoting an ambiguous Plex token. This is a product
decision, not solvable by a selector or a “migration complete” Boolean alone.

**Rollback boundary:** pre-commit errors leave legacy intact and new partial data
ineligible. After commit, ship a forward fix using the new domain; do not silently
dual-write or re-enable legacy fallback. Old binaries ignore migration markers and can
resurrect retained credentials or miss new-only sign-ins. Supporting a downgrade to
those binaries requires a separate compatibility/security decision. No safe promise
of both arbitrary old-binary rollback and persistent sign-out can be made here.

## Concrete validation matrix for implementation

All values below must be synthetic. Unit tests should inject a recording Security
adapter and assert exact query dictionaries, results, mutation counts, and ordering.
Do not use production services or launch a production bundle for these tests.

| Scenario | Required result/evidence |
| --- | --- |
| Old-only, no marker | Eligible complete set copied once; identifier unchanged; verified commit before source cleanup. Ambiguous Plex token uses approved recovery policy. |
| New-only | Reads succeed with no legacy call, prompt, or source deletion. Local accounts stay sync=false. |
| Both, equal or conflicting | New committed set wins; old never overwrites it; no automatic cleanup UI. Incomplete new set resumes safely. |
| Neither, authorized domain | Return absent; create identifier only after proving absence in all eligible domains. Missing credentials remain missing. |
| Deny/cancel/locked/unavailable/missing entitlement | Inject each at primary, legacy, read-back, marker and delete stages. Preserve all old data, no downstream fallback/write on failed reads, no per-scene retries; explicit recovery only. |
| Bad payload / partial backend | Success status with invalid bytes is invalidData, not absent; no generated replacement. Reject incomplete mixed backend snapshots. |
| Write/marker failure; process crash | Fail each copy and commit boundary; restart remains idempotent. No rollback deletion of unreadable prior values. Duplicate insertion rechecks winner. |
| Sign-out, 401, sign-out-all | Marker precedes deletion; failed marker/delete reported; no stale re-promotion after restart; identifier retained; inactive/backend-specific credentials follow existing policy. |
| iCloud remote update/delete | New token wins; deletion after observed primary stays signed out across restart even if legacy cleanup denied. Before-first-observation ambiguity follows recovery policy. tvOS is local-only. |
| Signature switches | Two appropriately provisioned synthetic app variants with same effective group: local/sync values survive A→B→A, changed build hashes, relaunch and lock/unlock without legacy prompts after commit. Wrong group/team and ad-hoc variants fail closed. |
| Rollback | Pre-commit retry preserves old data. Post-commit forward fix preserves new authority. Demonstrate old-binary incompatibility rather than claiming it safe. |
| Isolation and regressions | Noncanonical Mac file storage stays isolated; iOS/visionOS behavior unchanged; no real stores queried; tests clean up only exact test service/accounts. |

Existing `KeychainSynchronizedCredentialMigrationPolicyTests` exhaust Boolean
primary/legacy combinations but cannot express OSStatus, domain, retirement, or crashes.
`AuthSecureStorageTests` cover write failure, identifier fallback, selection, sign-out,
and multi-field rollback using synthetic services/development files; they lack a read
interceptor and do not establish denied-read or signature-switch safety.
`CredentialArtifactStorageTests` cover fallback/protection rules. Extend these seams
before Security integration. No speculative test implementation was added: testing a
new standalone model now would not validate the production adapter.

## Evidence and remaining gates

This change is documentation only. The hermetic PMSKit suite and repository docs/hygiene
checks are the applicable automated gates; their results are recorded in the private
`build/workflow/state.json` receipts and `build/workflow/343-*.log`. Product runtime
and signed keychain migration are **not tested**. No app-code runtime gate is claimed.

Before shipping, a human must approve recovery UX, legacy retention/cleanup timing,
ambiguous pre-sync Plex recovery, and the old-build downgrade boundary. Then provision
dedicated test identities/groups, verify effective entitlements/profiles, and exercise
the matrix on an isolated macOS user/test keychain context. A plain unsigned command-line
probe cannot prove entitled data-protection sharing. Testing real production sessions
or launching the production identity remains separately authorized human work.
Update canonical persistence/Mac guidance only when behavior is implemented and verified.
Recommended integration: cherry-pick this report onto the continuing `downloads/overhaul`
history; keep #343 open and treat implementation as a follow-up with these gates.
