# macOS shell and sidebar redesign

**Status:** Approved and active; implementation is owned by the #232 worktree.
**Issue:** [#232 — Mac shell/sidebar redesign pass](https://github.com/jlipworth/Labstream/issues/232)
**Approved decision record:** [post-audit Mac shell plan](https://github.com/jlipworth/Labstream/issues/232#issuecomment-5023765952)
**Acceptance boundary:** Keep #232 open until the user approves the redesigned shell visually and interactively.

**Current checkpoint:** Implementation and local verification are complete in commit `69465a4c8990`
on `codex/issue-232-mac-sidebar`, created from detached commit `7fc0cc63`. Native normal- and
narrow-width evidence has been captured and the
[#232 progress handoff](https://github.com/jlipworth/Labstream/issues/232#issuecomment-5024304901)
is posted. The remaining boundary is user visual/interaction acceptance. The checklist and dated
journal below are the current status source; older journal entries are historical evidence, not
newer instructions.

## Objective

Replace the sparse first-pass Mac sidebar with a deliberate, native macOS source list. Keep the work Mac-specific, retain full-window player ownership, and avoid changing the iPhone, iPad, or visionOS shells.

## Approved product direction

### Source list

- Show **Home** unsectioned at the top.
- Do not put Search in the sidebar and do not add an All Libraries row.
- Show a **Libraries** section containing the active server's visible non-music libraries in server order.
  - Exclude hidden and music libraries.
  - Use server names and native media-type symbols.
  - Disambiguate duplicate visible names accessibly only when duplicates actually occur; do not
    add persistent server/account clutter.
  - Selecting a library opens its grid directly and resets stale detail navigation.
  - Hide the section when no qualifying libraries exist.
  - Refresh destinations on backend/server changes and fall back to Home when a persisted destination disappears.
- Show a **Music** section containing **Music Home**, **Artists**, **Albums**, and **Playlists**.
  - Hide the section when no visible music library exists.
  - Hide unsupported destinations rather than disabling them.
  - Combine multiple music libraries where the backend supports trustworthy aggregation.
  - Otherwise, Music Home owns the library picker and its selection scopes Artists, Albums, and Playlists.
- Keep **Offline** as an always-visible standalone bottom row, including when empty.
- Remove the passive Status section. Account, server, and connection details remain in native Settings; do not add a sidebar identity/footer treatment.

### Offline progress

- Show an integer percentage only when at least one row is actively transferring bytes and every actively transferring row has a trustworthy expected total.
- Compute a byte-weighted aggregate: `sum(transferred bytes) / sum(expected bytes)`.
- Exclude queued, preparing, paused, failed, and completed rows.
- Treat locally complete-but-unverified rows as completed for this eligibility rule; they are not
  active byte transfers.
- If any active total is unknown, omit the percentage rather than showing a partial aggregate.

### Search and toolbar

- Remove the duplicate Offline toolbar button but retain **Shift-Command-D**.
- Prefer a native Mac toolbar search field backed by the existing global search and debounce/cancellation behavior.
- **Command-F** focuses Search. Search temporarily replaces the detail area while preserving its prior sidebar destination and navigation state.
- Clearing Search restores the prior destination. Escape dismisses Search before ordinary back navigation; selecting a sidebar destination also clears Search.
- Search collapses naturally in constrained toolbar space and disappears in player mode.
- Keep the existing icon/focused-results implementation only if native-field UI evidence demonstrates that the field is materially worse or destabilizes the toolbar.
- Preserve existing native back-navigation and Settings access.
- Use the standard source-list presentation without custom cards, spacing, counts, or badges beyond
  the approved trustworthy Offline percentage.

### Window, restoration, and account safety

- Use native `NavigationSplitView`/source-list behavior rather than a custom sidebar.
- Show the sidebar by default at normal widths; automatically collapse to detail-only at narrow widths while retaining the native sidebar toggle.
- Evaluate reducing the current 980-point minimum width, beginning around 720–800 points, and choose the smallest width proven usable across real browse and player surfaces.
- Restore the last valid destination across relaunch/window restoration. Persist backend/server/library identity, not only a display name; every invalid destination falls back to Home.
- Preserve compact Mac density rather than touch-sized controls.
- Keep the player in complete ownership of the window with unrelated root toolbar/sidebar/titlebar chrome hidden.
- Route **Account > Sign Out** through explicit confirmation; never expose immediate destructive sign-out in the sidebar or toolbar.

## Implementation phases and current checklist

### Phase 0 — audit and pure policies

- [x] Read `CLAUDE.md`, the complete issue body/comments, and the approved decision record.
- [x] Create `codex/issue-232-mac-sidebar` because the assigned worktree began detached.
- [x] Audit current library visibility/order models, music-provider capabilities, Search state and
  cancellation, Offline progress provenance, navigation-path ownership, persistence, and Mac
  window/toolbar behavior.
- [x] Add small pure policies for sidebar destination derivation and stable restoration/fallback.
- [x] Add a pure trustworthy Offline aggregate-percentage eligibility/calculation policy.
- [x] Cover ordering/filtering, capability gating, duplicate-name accessibility, stable identity,
  invalid restoration, and Offline eligibility with deterministic Plex/Jellyfin/Emby fixtures.

### Phase 1 — Mac source list, routing, and restoration

- [x] Load the active server's visible libraries through existing backend/application models.
- [x] Implement the Mac-only Home, dynamic Libraries, Music, and standalone Offline source list.
- [x] Route a library row directly to its grid and reset stale library detail navigation.
- [x] Preserve first-run and Settings-driven library visibility behavior.
- [x] Refresh on backend/server/visibility changes and restore or fall back using stable identities.
- [x] Keep iPhone, iPad, and visionOS shell behavior unchanged.

### Phase 2 — Music, Search, commands, and account safety

- [x] Record the backend music-aggregation decision and make child destinations share the explicit
  selected-library context wherever aggregation is not trustworthy.
- [x] Gate Playlists on actual backend capability.
- [x] Implement transient native toolbar Search using the existing result/debounce/cancellation
  flow, including Command-F, live results, detail replacement/restoration, Escape/sidebar
  dismissal, constrained toolbar behavior, and player hiding.
- [x] Remove the duplicate Offline toolbar action while preserving Shift-Command-D.
- [x] Route Account > Sign Out through explicit confirmation.
- [x] Preserve back navigation, Settings, and full-window player ownership.

### Phase 3 — sizing, automated verification, and native evidence

- [x] Exercise candidate minimum widths around 720–800 points and select the smallest proven value.
- [x] Run focused policy tests, the complete `LabstreamMac` test plan, relevant PMSKit tests, the
  complete PMSKit suite, and a clean native Mac build.
- [x] Launch the per-worktree native host app and check every interaction/evidence gate below at
  representative normal and narrow widths.
- [x] Follow the `CLAUDE.md` host cleanup rules after native checks.

### Phase 4 — review, commit, and external acceptance

- [x] Review scope/public-data hygiene and promote proven durable behavior into current docs where
  appropriate.
- [x] Commit the coherent completed implementation, tests, plan, and evidence references.
- [x] Post a concise #232 progress comment with commit, builds/tests, UI evidence, delegated
  decisions, and remaining user acceptance. Do not close #232.
- [ ] Record user visual/interaction acceptance. Until then this plan remains active and #232 stays
  open.

## Delegated implementation questions

These questions are delegated to the implementation task under the approved decision rules. Ask the user only if evidence reveals a product tradeoff not covered here.

1. **Search presentation:** use the native toolbar field unless real UI evidence supports the icon fallback.
2. **Compact breakpoint/minimum width:** select an evidence-backed value after exercising Home, libraries, music, Offline, details, and player—not to satisfy a predetermined number.
3. **Music aggregation:** verify each backend's actual semantics; combine only when trustworthy and otherwise use the explicit Music Home library selection.
4. **Restoration identity:** test removed/hidden libraries, backend/server changes, and newly unsupported music capabilities; invalid routes always fall back to Home.
5. **Library presentation:** disambiguate genuinely duplicate visible names accessibly without adding persistent server/account clutter.
6. **Density:** retain standard source-list rows, selection, spacing, and toggle behavior. Do not add counts or badges beyond the approved Offline percentage.

## Verification and acceptance gates

- Pure tests cover destination ordering/filtering, music capability visibility, persisted-route fallback, and aggregate Offline percentage behavior.
- Deterministic fixtures exercise Plex, Jellyfin, and Emby destination derivation.
- Mac build and relevant PMSKit/app test suites pass.
- Native Mac checks cover backend changes, direct library routing/path reset, Music Home and child destinations, Search focus/live results/dismissal, Offline percentage eligibility, keyboard shortcuts, player entry/exit, narrow collapse/toggle, restoration, and Sign Out confirmation.
- Representative normal-width and narrow-width screenshots or equivalent UI evidence are attached or linked for review.
- User visual and interaction acceptance is received before #232 closes.

Automated evidence must specifically prove server ordering and hidden/music filtering across Plex,
Jellyfin, and Emby normalized fixtures; Music/Playlists capability omission; duplicate-name-only
accessible disambiguation; foreign, removed, hidden, and unsupported persisted-route fallback; and
a byte-weighted Offline integer only when every `.downloading` row has an exact total. Estimated or
partially-known totals must produce no percentage.

Normal- and narrow-width native evidence must make source-list ordering/density/section omission,
direct library routing, Music selected-library context, Offline empty/progress states, native Search
focus/live/dismiss/restore behavior, constrained toolbar layout, native sidebar collapse/toggle,
player entry/exit, Command-F, Shift-Command-D, Escape ordering, back navigation, Settings, Sign Out
confirmation, and the selected minimum width reviewable. Use the native macOS host lane; do not boot
a simulator without an explicit lease. Keep committed/public evidence free of tokens, private
hostnames, library paths, and private media titles.

## Current implementation findings

- The existing Plex and MediaBrowser artist/album APIs are library-scoped and the current Music UI
  already owns a selected-library picker. No trustworthy cross-library aggregation contract has
  been found, so the current implementation direction is to share Music Home's explicit selection
  across Artists and Albums for Plex, Jellyfin, and Emby unless later evidence disproves this.
- Plex exposes account-level audio playlists. Jellyfin/Emby playlist support is discoverable from a
  playlists user view and should be hidden when that capability evidence is absent.
- SearchView already owns a 300 ms `.task(id:)` debounce plus captured authority/cancellation
  checks. The native Mac field should bind into that flow rather than create another fetch engine.
- `AppModel.activeStableServerUserKey` is the existing token-free stable server/user scope used for
  library visibility and is suitable for scoping persisted route identities.
- Download row progress may use a transcoder estimate. The source-list percentage must instead use
  only exact live expected bytes or an exact static source-part size.
- The native half-screen exercise left only about 670 points beside the standard 230-point source
  list. The current evidence-backed policy keeps a 760-point window minimum and switches
  `NavigationSplitView` to detail-only below 900 points, while retaining the native toolbar toggle;
  normal restored/default widths continue to show the sidebar.

## Acceptance journal

### 2026-07-20 — Plan approved

- Product decisions were triangulated with the user and recorded in the authoritative GitHub comment.
- Implementation was assigned to `codex/issue-232-mac-sidebar` in a dedicated worktree.
- Implementation, automated verification, Mac UI evidence, and user acceptance remain pending.

### 2026-07-20 — Implementation opened and repository plan adopted

- Read repository guidance and all issue content, then created the required branch from detached
  baseline `7fc0cc63`.
- Audited the initial Mac shell, backend library and visibility models, music API scope, SearchView
  state flow, download progress provenance, navigation/window command ownership, and Settings
  confirmation behavior.
- Adopted this directly supplied active-plan file and index entry as the canonical resumable
  implementation/acceptance journal before continuing code work.
- Pure policy implementation has begun but is not yet compiled or verified. Builds, tests, host UI
  evidence, commit, issue progress comment, and user acceptance remain pending.

### 2026-07-20 — Implementation and local verification complete

- Implemented the Mac-only native source list, stable route restoration/fallback, direct library
  routing, capability-gated Music destinations with shared selected-library context, trustworthy
  Offline aggregation, native toolbar Search, narrow collapse, and confirmed sign-out.
- Deterministic Plex, Jellyfin, and Emby policy fixtures passed. The focused Mac policy suite passed
  6 tests, the focused Offline policy suite passed 6 tests, and the complete PMSKit suite passed
  1,603 tests in 205 suites.
- The complete Mac test plan passed 320 tests in 35 suites with test parallelization disabled. Two
  default-parallel runs exposed unrelated timing-sensitive tests; both tests and the six sidebar
  policies passed together in a focused eight-test rerun. Generic iOS and visionOS builds passed
  without booting a simulator, as did the clean signed native Mac build. Repository hygiene passed
  all 48 Python tooling tests, a strict documentation build, and the Mermaid source/render check.
- On the signed-in Plex backend, native checks covered direct source-list selection, Music Home and
  child routing, Command-F live debounced Search and both dismissal paths, Shift-Command-D, Escape
  ordering, back navigation, narrow collapse/toggle, persisted restoration, full-window player
  entry/exit, and sign-out confirmation.
- Privacy-safe normal- and narrow-width screenshots were captured for task review. Every staged
  worktree app was terminated and removed before fresh reloads and again after final checking;
  `/Applications/Labstream.app` and persisted production state were not changed.
- The native field remained stable at constrained width, so the icon fallback was not used. A
  760-by-640 minimum with detail-only presentation below 900 points was the smallest usable result.
  Cross-library artist/album aggregation was not trustworthy on current APIs, so all backends use
  the explicit selected-library context; Plex playlists are account-level, while Jellyfin/Emby
  Playlists require a discoverable playlist view.
- The implementation is committed as `69465a4c8990`. The concise
  [#232 progress comment](https://github.com/jlipworth/Labstream/issues/232#issuecomment-5024304901)
  records the build/test evidence and delegated decisions. User visual/interaction acceptance
  remains; #232 stays open and this plan remains active.

## Lifecycle

When accepted, promote durable Mac behavior into the relevant current architecture/development documentation, move this file to `docs/archive/plans/` without rewriting its journal, and repair live links.
