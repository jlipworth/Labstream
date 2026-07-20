# Diagnostics and privacy

Labstream diagnostics are for user-initiated debugging, not analytics.

```mermaid
flowchart TD
  accTitle: Diagnostic redaction and export
  accDescr: Typed runtime events are redacted before reaching the in-memory ring or rotating local files. MetricKit summaries are separately redacted, and only a user action assembles local material into a report for explicit sharing.
  Toggle[User enables logging] --> Ring[300-event in-memory ring]
  Runtime[Runtime events] --> Fields[Typed diagnostic fields]
  Fields --> Redactor[Redaction]
  Redactor --> Ring
  Redactor --> Files[Rotating redacted JSONL files]
  MetricKit[MetricKit diagnostic summaries] --> MXRedact[Redacted local summaries]
  Ring --> Report[Diagnostic report]
  MXRedact --> Report
  Report --> Preview[User preview]
  Preview --> Copy[Copy/export/share]
```

## Contract

- Diagnostic event logging is off by default.
- Events stay local in a 300-event process ring and, while logging is enabled, one
  approximately 1 MB JSONL file plus up to three rotated archives. The disk copy is
  already redacted and exists for user-initiated headset evidence after suspension or termination.
- Reports are copied, exported, or shared only after a user action.
- The app does not upload diagnostic reports.
- Reports must omit or redact tokens, client identifiers, hostnames/IP addresses, full URLs, usernames, library paths, filenames, and media titles.
- Free-form user notes are best-effort scrubbed, but users should still review the preview before posting publicly.

## Typed fields

Use `DiagnosticFieldValue` constructors instead of raw strings:

- `.label` for safe categorical labels;
- `.text` only for intentionally safe text;
- `.urlShape` for scheme/path-shape reporting without hosts/tokens;
- `.identifier` for stable-but-redacted identifiers;
- `.error`, `.bytes`, and bucket helpers for safe summaries.

The redaction layer runs when fields are constructed and when reports are rendered. Do not add raw URLs, tokens, server names, usernames, paths, filenames, or media titles to diagnostic fields.

## Report contents

A report may include:

- app version/build and OS/device class;
- active backend;
- server product/version where safe;
- connection scheme, not host;
- selected quality settings;
- Adaptive Bitrate state;
- bucketed download counts, queue state, storage totals, and conservative orphan-candidate totals;
- recent playback snapshot;
- passive redacted MetricKit crash/hang/CPU/disk-write diagnostic summaries;
- up to 80 recent redacted events from the current process ring.

The in-app report does not reload the rotating JSONL files. Those files are collected only by the
repository's explicit evidence tooling, and still require the user to review anything before sharing it.

The Mac development preview uses the same typed/redacted report pipeline and may add safe platform,
effective bundle-identity, sandbox-storage, download, and playback facts. Per-worktree bundle IDs
and container paths must not be emitted as raw identifiers or filesystem paths.

## Public issue reminder

GitHub issues are public. The app and docs ask users to review diagnostic reports, screenshots, videos, and logs before submitting because automated redaction cannot understand every personal detail in free-form prose or images.
