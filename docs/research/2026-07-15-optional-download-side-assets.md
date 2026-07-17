# Optional download side-asset request policy

This note records the request-family audit behind the process-wide side-asset coordinator. It intentionally contains no server URLs, media identifiers, filenames, credentials, or infrastructure details.

## Before and after

Before this change, each download independently launched optional cache tasks. Chapter images and Jellyfin trick-play tiles used per-download batches of four, while poster, subtitle, and index work could overlap those batches. Two simultaneous downloads therefore had no process-wide request-start bound. The observed regression involved 84 chapter-image requests (32 plus 52) in about five seconds, with up to eight chapter requests in flight before other side assets were counted.

After this change, optional fetches share one process-wide coordinator, partitioned by normalized server origin. The sole tuning surface is `SideAssetRequestPolicy`: by default each origin admits at most one new request per second and two requests concurrently. The start interval is derived from the rate. These defaults are deliberately conservative relative to the two-events-per-second crawl-rule leak rate observed in the incident; they are an application safety policy, not media-server protocol constants.

Owners at one origin are admitted round-robin. Identical method/URL/header/body requests coalesce only in memory and only within the same origin, so distinct authorization contexts cannot be mixed. Request identities are neither logged nor persisted. Pause and Pause All park optional work and cooperatively cancel/requeue its active fetch; resume continues it. Delete or replacement cancels the exact attempt's interest. A nonempty regular file is reused only when exact-attempt metadata already references it. Partial chapter, subtitle, and trick-play successes are merged rather than replaced.

## Request-family inventory

| Family | Backend | Classification | Before | After / direct fix |
|---|---|---|---|---|
| Poster/artwork | Plex, Emby, Jellyfin | Optional hydration | One independent task per download; overlapped every other family; no global pacing | Coordinator; exact-attempt file reuse |
| Text subtitles | Plex, Emby, Jellyfin | Optional hydration | Task-group fanout by selected tracks; no global bound, cancellation only at task level | Coordinator per file; valid cached tracks reused and metadata merged |
| Chapter images | Emby, Jellyfin | Optional hydration | Four concurrent per download, so simultaneous downloads multiplied the batch; no global pacing | All requests submitted fairly to coordinator; exact-attempt reuse and dictionary merge |
| Plex BIF index | Plex | Optional hydration | One independent request per download, overlapping poster/subtitles | Coordinator and exact-attempt reuse. BIF frames are parsed locally; no per-frame network requests |
| Trick-play manifest and tiles | Jellyfin | Optional hydration | Playlist direct, then four tiles concurrently per download; no process-wide pacing | Playlist and missing tiles use coordinator; existing referenced tiles reused; sanitized playlist and tile metadata merged |
| PlaybackInfo / download negotiation | Emby, Jellyfin (and equivalent Plex selection metadata) | Essential control plane | One request at preparation/handoff or retry; not a fanout loop | Deliberately unthrottled; stale-attempt currency guards prevent a late response restarting cancelled work |
| Optimize/convert status polling | Plex, Emby | Essential preparation control plane | One poller per exact attempt with existing cadence/backoff and pause gates | Deliberately unthrottled; no accidental tight retry loop found |
| Retry/resume and reconciliation | All | Essential lifecycle | Exact-attempt/store guards, retry schedules, and cold-launch reconciliation can hand off work; optional cache entry points previously could duplicate | Side-cache registry now uses atomic `startIfAbsent`; exact-attempt coordinator owners park/cancel across handoff |
| Media-byte transfer | All | Essential data plane | Background URLSession transfer; static lanes may use range resume/restart | Deliberately unthrottled |
| HEAD/range probes and held-range sidecars | All applicable static lanes | Essential transfer validation/recovery | Serialized by existing transfer/recovery machinery | Deliberately unthrottled; not optional hydration |
| Keepalive/report pings | Emby, Jellyfin | Essential control plane | Existing per-attempt cadence | Deliberately unthrottled |

No separate unguarded metadata-poll, preparation-poll, retry, or HEAD/range loop was found that should be hidden behind the optional-work limiter. Those paths retain their existing purpose-specific pacing and cancellation semantics.

## Residual considerations

The default intentionally trades slower offline thumbnail completion for safety. Different origins progress independently; multiple hostnames or ports for one physical server are separate origins. The coordinator performs no broad retry rewrite: existing callers remain best-effort, and failures can be retried by the established download retry/reconciliation lifecycle. Live-server validation should confirm that pausing during a long side cache stops new starts and that resuming reuses already-published files.
