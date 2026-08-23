# Jellyfin public-demo evaluation for screenshots and App Review

**Status:** active research; do not treat the public service as the accepted App Review
environment yet.

## Question

Can Labstream use Jellyfin's official public stable demo for cross-platform storefront screenshots
and Apple's reviewer journey, avoiding a dedicated review server?

## Confirmed on 2026-08-22

- Jellyfin explicitly identifies its public demo as an exception provided for evaluation and
  testing in its [server policy](https://jellyfin.org/docs/general/community-standards/servers/).
  Its client-testing documentation also directs testers to the stable/unstable demo and says the
  login page provides credentials.
- `https://demo.jellyfin.org/stable/` was reachable and reported Jellyfin Server 10.11.11.
- The stable service exposed a shared passwordless account, Quick Connect, and Movies, Shows,
  Music, and Playlists libraries. The visible catalog included Blender shorts and older/open-media
  film and television material with poster/backdrop art.
- A credential-ephemeral PMSKit live probe passed the shared views, items, and metadata wrappers:
  HTTP 200 for all three. No token, session, item identifier, server-internal address, or response
  body was retained. Timeline mutation was deliberately not enabled against the shared account.
- The public account policy disabled media downloads. Shared preferences were mutable, so another
  visitor can change language and presentation state.
- Passwordless Jellyfin sign-in landed through
  [issue #283](https://github.com/jlipworth/Labstream/issues/283) and
  [PR #284](https://github.com/jlipworth/Labstream/pull/284). The UI now requires the server and
  username but allows an empty password, while Emby and Plex validation remain unchanged. A
  transient authentication/logout check against the stable demo passed without retaining a token.

## Current interpretation

| Use | Current verdict | Reason |
| --- | --- | --- |
| PMSKit compatibility testing | Suitable | Official test purpose and live browse/metadata proof. |
| Screenshot workflow prototyping | Suitable with review | Realistic catalog and artwork, but selected visible assets still need license provenance. |
| Final public storefront screenshots | Unresolved | Access to a demo does not by itself establish third-party marketing rights for every downloaded metadata image. |
| Complete Apple reviewer account | Not yet suitable | Shared mutable state, disabled downloads, possible reset interruptions, and no Labstream-controlled availability. |

Jellyfin has historically told public-demo testers that the service resets hourly, and its own
vendor-certification discussion describes separate private vendor environments. Those records are
useful risk evidence, but the current reset schedule must be revalidated rather than assumed from
an older issue.

The public catalog's media may be public domain or Free Culture, but that does not automatically
prove the provenance of every poster, logo, backdrop, or third-party metadata-provider image.
Only assets with an auditable source/license should appear in Labstream's final screenshots.

## Exit criteria

1. [x] Merge #283, validate the request against the stable demo, and preserve Emby/Plex behavior.
   Clean-install reviewer-journey testing remains part of criterion 2.
2. Exercise browse, details, artwork, playback, and platform navigation against the stable demo on
   iPhone, iPad, Mac, Apple TV, and Apple Vision Pro.
3. Identify a screenshot title/artwork subset with source, license, attribution, and marketing-use
   permission recorded in a repository manifest.
4. Observe whether resets or shared-state changes make deterministic capture or multi-day review
   instructions unreliable.
5. Decide whether disabled downloads prevent Apple from receiving sufficient access to the
   submitted iOS/iPadOS, macOS, and visionOS products.

If any final-use criterion fails, provision a minimal Labstream-controlled Jellyfin environment.
A container or small Proxmox LXC is preferable to a full VM when the existing infrastructure and
security boundary allow it. A public-domain library generator such as
[`stdjflib`](https://github.com/iwalton3/stdjflib) may reduce catalog setup work, but it requires a
separate source/security/license review before deployment.
