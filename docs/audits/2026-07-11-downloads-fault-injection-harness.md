# Downloads Engine Fault-Injection Harness (Phase 6)

Phase 6 now has a smallest-real transport harness: a DEBUG-only `URLProtocol` drives the
foreground `URLSession` owned by the real `BackgroundDownloadSession`. It does not model or call
the range policies directly. Real download tasks, delegate ordering, temp-file stashing, durable
append, validator restart, and request-rehydration callbacks remain in the exercised path.

There is no Labstream app unit-test target in `Labstream.xcodeproj`; the only unit-test target is
the PMSKit Swift package, which cannot construct the app-internal session/store types. Therefore
these are executable simulator probes, not claimed automated unit coverage. The injectable
`protocolClasses` initializer seam exists for a future app test target and deliberately selects an
in-process foreground session (custom URL protocols do not run in the device background daemon).

## Driver

Use a signed-in Plex simulator and select a static-download item larger than one 512 MiB segment.
The existing connection-drop contract remains the default:

```sh
scripts/probe-plex-range-drop.sh --rating-key KEY --delete-after
```

The first two priority Phase 6 scripts are:

```sh
scripts/probe-plex-range-drop.sh --rating-key KEY --fault validator-flip --delete-after
scripts/probe-plex-range-drop.sh --rating-key KEY --fault 401-mid-train --delete-after
```

The script builds/installs the DEBUG app, launches the existing Plex download probe, captures
Downloads/DownloadProbe unified logs, and exits nonzero unless both the requested injected fault
and its engine reaction appear. `--query TEXT` may replace `--rating-key KEY`; all prior range-drop
options remain supported.

## Deterministic scenarios and pass criteria

### `validator-flip`

The protocol assigns synthetic ETag v1 to the first zero-offset body and v2 to every other body.
That assignment happens when each protocol load starts, so completion order cannot erase the flip:
if an ahead segment pins v2 first, the delayed v1 body conflicts; if offset zero pins v1 first, the
first ahead body conflicts. A restarted zero-offset request receives v2, modeling a resource that
stabilized after changing.

Required diagnostics:

- `downloads.fault_injected` with scenario `validator-flip`
- `downloads.range_validator_changed`

The engine must supersede the old train/restart from the durable safety boundary; the probe fails
if it only proves the transport mutation without reaching the changed-resource path.

### `401-mid-train`

The protocol synthesizes exactly one HTTP 401 for the first positive-offset segment it sees and
proxies every other request normally. This makes the fault bounded while still entering through a
real closed-range task in the active train.

Required diagnostics:

- `downloads.fault_injected` with scenario `401-mid-train`
- `downloads.range_http_rehydrate`

The bad response body must not append. The engine resets displayed progress to the durable
checkpoint, enters request-rebuild grace, and asks `DownloadManager` for a fresh authenticated
request. The probe fails if the 401 does not reach that rehydration path.

## Scope still open

Pause-mid-drain, repeated counter-reset/blob adoption, relaunch with on-disk stashes, and injected
filesystem write failure remain later Phase 6 cells. They need lifecycle/filesystem control beyond
the transport seam and should not be simulated by bypassing the real session.
