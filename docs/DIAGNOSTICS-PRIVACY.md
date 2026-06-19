# Diagnostics and privacy

VisionPlay diagnostics are for user-initiated debugging, not analytics.

## Contract

- Diagnostic logging is off by default.
- When enabled, events stay in a bounded local ring buffer.
- Reports are copied/exported only when the user taps the copy action.
- No diagnostic report is uploaded by the app.
- Reports must omit or redact tokens, client identifiers, hostnames/IP addresses, full URLs, usernames, library paths, filenames, and media titles.

## Typed fields

Use `DiagnosticFieldValue` constructors instead of raw strings:

- `.label` for safe categorical labels such as backend, state, route, codec/container labels, and quality labels.
- `.text` only for intentionally safe human-readable text.
- `.urlShape` for scheme/path-shape style reporting without full hosts/tokens.
- `.identifier` for stable-but-redacted identifiers.
- `.error`, `.bytes`, and bucket helpers for safe summaries.

The redaction layer runs at field construction/rendering time. Do not add raw URL/token/server/title strings to diagnostic fields.

## Report contents

The report may include:

- app product/version/build and OS/device class
- backend name
- server product/version where safe
- connection scheme, not host
- selected quality settings
- recent playback snapshot when present
- recent redacted event summaries

It must not include the user’s Plex server name, Jellyfin server URL, raw hostname/IP, tokens, media titles, or filesystem paths.

## Profiling

Committed profiling baselines should be small, manually reviewed, and privacy-safe. Use backend/scenario names without titles or server names. See [`PROFILING.md`](PROFILING.md) and [`profiling/baselines/README.md`](profiling/baselines/README.md).
