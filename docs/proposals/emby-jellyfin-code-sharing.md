# Proposal: a future shared "emby-family" seam for Jellyfin + Emby

Status: PROPOSAL for human review. Nothing here is implemented. Do not refactor Jellyfin to satisfy this document — it exists to capture the option and stage it safely.

Scope owner: backend lanes (`PMSKit/Sources/PMSKit/Jellyfin/*`, `PMSKit/Sources/PMSKit/Emby/*`, and the app-layer `*BrowseService`s). Plex is explicitly out of scope.

## Why this proposal exists

Jellyfin is an upstream fork of Emby, and after implementing the first Emby slice as a deliberately parallel lane (see [`../research/17-emby-backend-support.md`](../research/17-emby-backend-support.md)), the overlap is now measured, not assumed:

- The request surface is ~90% identical: `POST /Users/AuthenticateByName`, `GET /Users/{UserId}/Items`, `/UserViews`, `/Items/{Id}`, `POST /Items/{Id}/PlaybackInfo`, `/Sessions/Playing[/Progress|/Stopped|/Ping]`, and `DELETE /Videos/ActiveEncodings` all exist on both, with the same query/body field names.
- The DTO surface overlaps heavily: both decode a `BaseItemDto`-shaped item (`Id`, `Name`, `Type`, `RunTimeTicks`, `ProductionYear`, `ImageTags`, `MediaSources[]` with `MediaStreams[]`), the same `PlaybackInfo` response (`PlaySessionId`, `MediaSources`, `TranscodingUrl`/`DirectStreamUrl`, `RequiredHttpHeaders`, `AddApiKeyToDirectStreamUrl`), and the same progress body shape.
- The live Emby server even **accepted the Jellyfin `MediaBrowser ` auth header** — direct evidence the two protocols share a common ancestor wire contract.

The current code reflects this as two near-duplicate lanes (`EmbyLibrary`/`EmbyPlayback`/`EmbyAuth` mirror `JellyfinLibrary`/`JellyfinPlayback`/`JellyfinAuth`). That duplication was the right call for the first slice — it let Emby be validated live without risking Jellyfin parity — but it is now a maintenance cost: a bug fix or new field in one lane must be hand-ported to the other.

This proposal lays out a future seam to collapse the proven-identical parts, the known divergences that must stay parameterized, the risk to Jellyfin parity, and a staged plan that keeps Jellyfin frozen until each shared piece is proven equivalent.

## Hard non-goals

- **No broad backend protocol.** Plex differs fundamentally (auth, stream resolution, timeline, downloads) and is not part of this seam. This is an "emby-family" seam only, matching the existing abstraction rule in [`../BACKENDS.md`](../BACKENDS.md).
- **No Jellyfin behavior change.** "Jellyfin must not regress" is the acceptance criterion. Any shared component must produce byte-identical `URLRequest`s and decode-identical DTOs for the Jellyfin lane before Jellyfin is switched onto it.
- **No speculative generality.** Only collapse parts that are proven identical on the wire for both servers. Where they differ, keep an explicit parameter, not a runtime "if backend == ..." branch buried in shared code.

## Known divergences that must remain parameterized

These are the differences the first Emby slice actually hit. A shared seam must express each as an explicit input, not erase it:

| Concern | Jellyfin | Emby |
| --- | --- | --- |
| Auth scheme prefix | `MediaBrowser ` | `Emby ` |
| Token header | (header in `Authorization`) | `Authorization` **plus** `X-Emby-Token` |
| `UserId` in header | not included | included in the `Authorization` value when known |
| PlaybackInfo `UserId` | body | **both** query and body |
| `AutoOpenLiveStream` | `true` | `false` |
| HLS child-resource auth | header/proxy path | `api_key=` in the server-generated URL; no per-child `Authorization` |
| Direct-stream fallback auth | (lane-specific) | `X-Emby-Token` header when `AddApiKeyToDirectStreamUrl == false` |
| Base path | (lane-specific) | user-entered `/emby` preserved verbatim |

## Proposed seam (future)

Three small, independently-shippable shared pieces, each behind a parameter object so neither lane's behavior is implicitly changed:

1. **Parameterized auth-header builder.** A single header builder that takes an `AuthScheme` value (`scheme: "MediaBrowser" | "Emby"`, `includeUserIdInHeader: Bool`, `extraTokenHeader: String?` e.g. `"X-Emby-Token"`). Each lane constructs its own `AuthScheme` constant; the builder logic (quoting, ordering, token/userId inclusion rules) is shared. This is the lowest-risk, highest-overlap piece.

2. **Shared `BaseItemDto`-style decoding.** A shared item/media-source/media-stream decoder (`EmbyFamilyBaseItemDto`, `…MediaSourceInfo`, `…MediaStreamDto`) with the common `CodingKeys`. Both lanes' `toMediaItem()` bridges call into it. Lane-specific fields, if any emerge, stay as lane-side extensions rather than polluting the shared type.

3. **Shared PlaybackInfo request/response + `resolveStream`.** Parameterize the divergences from the table (`userIdInQuery: Bool`, `autoOpenLiveStream: Bool`, `streamAuth: .apiKeyInUrl | .header(name:)`, base-path join). The stream-preference order (`TranscodingUrl` → `DirectStreamUrl` → synthesized direct-play) is already identical and can be shared directly.

The device profile and progress-body builders are candidate follow-ups once the above three are proven.

Naming: a `PMSKit/Sources/PMSKit/EmbyFamily/` directory (or `MediaBrowserCommon/`) keeps the seam visibly scoped and prevents accidental Plex coupling.

## Risk to Jellyfin parity

The dominant risk is silently changing the Jellyfin wire shape while "just refactoring." Mitigations, required before any Jellyfin switchover:

- **Golden-request tests.** Before extracting, capture the exact `URLRequest` (method, URL, sorted query, sorted headers, body bytes) the current Jellyfin lane produces for every endpoint, as fixtures. The shared builder must reproduce them byte-for-byte. The existing `Jellyfin*Tests` are the starting point.
- **Golden-decode tests.** Pin current Jellyfin DTO decoding against recorded response fixtures; the shared decoder must produce identical `MediaItem`s.
- **One lane at a time, Emby first.** Move Emby onto each shared piece first (Emby is newer, lower blast radius, and already has `LiveEmbyProbe`). Only after Emby rides the shared piece and both unit + live probes pass does Jellyfin switch — guarded by the golden tests above.
- **Keep the auth-scheme divergence loud.** The `MediaBrowser`-accepted-by-Emby coincidence must NOT become "send `MediaBrowser` to Emby." Each lane keeps its canonical scheme constant; the builder is shared, the scheme value is not.
- **No shared mutable/runtime backend switch in hot paths.** Divergences are compile-time parameter objects per lane, so a Jellyfin call can never accidentally take an Emby branch.

## Staged plan

1. **Stage 0 — freeze + fixtures (no code moves).** Land golden-request and golden-decode fixtures for both lanes. Pure additive; nothing shared yet. This stage is itself a useful regression net even if the seam never lands.
2. **Stage 1 — shared auth-header builder.** Extract behind `AuthScheme`. Switch Emby first, then Jellyfin once golden-request tests pass for both.
3. **Stage 2 — shared `BaseItemDto` decoding.** Extract the common item/source/stream decoders. Switch Emby, then Jellyfin under golden-decode tests.
4. **Stage 3 — shared PlaybackInfo + `resolveStream`.** Parameterize the table divergences. Switch Emby (re-run `LiveEmbyProbe`), then Jellyfin.
5. **Stage 4 — optional follow-ups.** Device profile and progress-body builders, only if Stages 1–3 land cleanly and the duplication still hurts.

Each stage is independently revertible and gated on "Jellyfin requests/decodes are byte-identical." If any stage shows a divergence not in the table above, stop and keep that piece lane-specific — the duplication is cheaper than a Jellyfin regression.

## Recommendation

Do not start this now. The Emby lane should bake (in-headset playback validation is still a device-only gate per [`../TESTING-STRATEGY.md`](../TESTING-STRATEGY.md)). Revisit when (a) Emby playback is headset-proven and (b) a real maintenance pain point appears — e.g. a fix that has to be hand-ported between the two lanes. At that point, start at Stage 0.
