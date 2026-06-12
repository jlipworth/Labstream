# Plex AVP Transcode/OOM Incident Report

Date written: 2026-06-12
Author: Codex agent (server-side / cluster investigation)
Related app/repo: VisionPlex (this repository)

## Executive summary

The Plex pod in Kubernetes OOM-killed twice while serving Apple Vision Pro style Plex API playback sessions. The strongest application-specific signal is that the relevant Plex transcode session IDs are prefixed `plex-avp-*`, matching the homegrown Vision Pro app naming.

The second crash appears to be caused by repeated Plex HLS transcode session creation for the same media item within a very short window. Plex was forced into software HEVC -> H.264 + EAC3 -> AAC transcoding, and a burst/retry/seek loop appears to have stacked many `Plex Transcoder` processes until the pod hit its 8Gi memory cgroup limit.

High-confidence finding: this is not node-wide memory pressure. It is Plex container/pod memory exhaustion caused by transcode workload amplification.

## Environment/context

- Kubernetes namespace: `media`
- Plex pod: `plex-698dd84fc5-h5kz4`
- Node: `k8s-02`
- Plex pod memory limit: `8Gi`
- Plex pod requests/limits observed:
  - request CPU: `500m`
  - request memory: `2Gi`
  - limit CPU: `8`
  - limit memory: `8Gi`
- Plex image in deployment/pod: `linuxserver/plex:1.42.2.10156-f737b826c-ls288`
- After restart, linuxserver container auto-upgraded Plex internally to `1.43.2.10687-563d026ea`; this happened after the OOM, so it is likely runtime drift, not the trigger.

## Alerts/events observed

Initial Wazuh alert:

- Alert: `WazuhSecurityEvent`
- Wazuh rule: `5108`
- Agent: `k8s-02`
- Description: `System running out of memory. Availability of the system is in risk.`
- Event ID: `1781187740.5106268`
- First event time: 2026-06-11 14:22:20 UTC / 2026-06-11 18:22:20 home-TZ

Second Plex OOM:

- Pod restart count increased to `2`
- Last state: `reason: OOMKilled`, exit code `137`
- Second OOM time from kernel/Plex logs: 2026-06-11 20:04:00 UTC / 2026-06-12 00:04:00 home-TZ / 2026-06-11 16:04:00 EDT on node logs

Current state after investigation:

- Plex was running and ready.
- No active `Plex Transcoder` / `av:hevc:*` processes were present after restart.
- Plex memory had fallen back to roughly 200-300Mi.
- `k8s-02` was healthy, `MemoryPressure=False`.
- Alertmanager had no active matching Wazuh/Plex/k8s-02 alerts at the time of checks.

## Why this points at VisionPlex / AVP client behavior

The Plex application logs show transcode sessions named like:

- `plex-avp-8E1F37BD-A9D1-47E3-ADC2-9440B53F337A`
- `plex-avp-22A6DB39-FCD0-435A-8486-10CE09FD9148`

The `plex-avp-*` naming strongly suggests the homegrown Apple Vision Pro client is creating or influencing these sessions.

The crash window is dominated by these AVP-prefixed transcode sessions for one media item.

## Media item involved

The repeated transcode sessions were for:

```text
/data/tv/Example Show/Season 2/Example Show - S02E02 - Example Episode WEBRip-2160p.mkv
```

Plex decision details seen in the logs:

- Protocol selected: HLS
- Container: MPEG-TS
- Input looked like MKV / HEVC / EAC3
- Plex decided:
  - Direct Play was disabled or unavailable.
  - The media had to be transcoded to use HLS.
  - No direct play video profile existed for `http/mkv/hevc`.
  - No direct play video profile existed for `http/mkv/hevc/eac3`.
  - No remuxable profile was found.
  - Video stream would be transcoded.
  - Audio stream would be transcoded.
- Transcode target observed:
  - Video: HEVC -> H.264 (`libx264`), 1920x1080, `veryfast`, about 7.4Mbps video maxrate.
  - Audio: EAC3/EAE -> AAC stereo, 48kHz, about 109kbps.

Critical detail: Plex logged hardware transcoding as enabled but unusable for this path:

```text
TPU: hardware transcoding: enabled, but no hardware decode accelerator found
TPU: hardware transcoding: final decoder: , final encoder:
```

So the workload fell back to CPU/software transcoding.

## Reconstructed timeline for the second crash

Times below are Plex/node-local EDT from logs. Convert +8 hours for home-TZ, +4 hours for UTC? Specifically, `Jun 11 16:04 EDT` == `Jun 11 20:04 UTC` == `Jun 12 00:04 home-TZ`.

### 15:58:00-16:00:07 EDT

A previous AVP session was active:

```text
plex-avp-84DE20CB-8DBB-4B27-877C-02635B4FA714
```

Summary from parsed Plex logs:

- First seen: `Jun 11, 2026 15:58:00.424`
- Last seen: `Jun 11, 2026 16:00:06.996`
- Lines associated: 762
- Transcode starts/jobs seen in this parsed window: 0 (already active before window)
- Host classes: loopback + cluster-ingress
- Max live request count seen: 8
- Segment GETs: 30
- Transcoder segment ranges: 32
- Whacked: 1

This session alone did not look catastrophic.

### 16:02:56-16:03:56 EDT: runaway session

A new AVP session appeared:

```text
plex-avp-8E1F37BD-A9D1-47E3-ADC2-9440B53F337A
```

Summary from parsed Plex logs in the pre-crash window:

- First seen: `Jun 11, 2026 16:02:56.871`
- Last seen before crash: `Jun 11, 2026 16:03:56.863`
- Lines associated: 2370
- Transcode session starts: 21
- Plex Transcoder jobs launched: 21
- Same media file each time: `Example Show - S02E02 - Example Episode WEBRip-2160p.mkv`
- Host classes:
  - cluster-ingress: 248 lines/requests
  - loopback: 1422 lines/requests
- Max live request count observed: 140
- HTTP statuses observed:
  - 200: 254
  - 204: 2
  - 206: 43
  - 404: 536
- Segment GETs: 240
- `Asked for segment` lines: 120
- `progress/streamDetail` lines: 1086
- Transcoder segment ranges: 87
- Plex attempted to whack the session: 2 times, but logs still said `1 remaining`.

This is the core suspicious pattern: many transcode jobs launched for one session/media item within about one minute.

Representative redacted log excerpts:

```text
Jun 11, 2026 16:03:55.001 ... Starting a transcode session plex-avp-8E1F37BD-A9D1-47E3-ADC2-9440B53F337A at offset 1501.0
Jun 11, 2026 16:03:55.002 ... TPU: hardware transcoding: enabled, but no hardware decode accelerator found
Jun 11, 2026 16:03:55.002 ... Using local file path instead of URL: /data/tv/Example Show/Season 2/Example Show - S02E02 - Example Episode WEBRip-2160p.mkv
Jun 11, 2026 16:03:55.002 ... TPU: hardware transcoding: final decoder: , final encoder:
Jun 11, 2026 16:03:55.002 ... Job running: ... "Plex Transcoder" -codec:0 hevc -codec:1 eac3_eae ... -ss 1501 ... -codec:0 libx264 ... -codec:1 aac ...
Jun 11, 2026 16:03:55.003 ... Jobs: Starting child process with pid 4236
Jun 11, 2026 16:03:55.003 ... Started session successfully: plex-avp-8E1F37BD-A9D1-47E3-ADC2-9440B53F337A
```

Then additional transcode starts for nearby/different offsets, same session/media:

```text
16:03:55.011 offset 1560.0 -> child process pid 4237
16:03:55.026 offset 1650.0 -> child process pid 4238
16:03:55.049 offset 1765.0 -> another transcode job
16:03:55.556 offset 1071.0 -> child process pid 4498
16:03:55.809 offset 1820.0 -> child process pid 4519
16:03:56.111 offset 1841.0 -> child process pid 4520
16:03:56.120 offset 1741.0 -> child process pid 4521
```

The session was also asking for lots of segments in the same period, including around segment numbers 2267-2403:

```text
Asked for segment 2267
Asked for segment 2279
Asked for segment 2283
Asked for segment 2298
Asked for segment 2307
Asked for segment 2320
Asked for segment 2381
Asked for segment 2399
```

Plex attempted to clean up/whack the problematic session:

```text
Jun 11, 2026 16:03:56.855 ... Whacked session plex-avp-8E1F37BD-A9D1-47E3-ADC2-9440B53F337A, 1 remaining.
Jun 11, 2026 16:03:56.863 ... Whacked session plex-avp-8E1F37BD-A9D1-47E3-ADC2-9440B53F337A, 1 remaining.
```

### 16:03:56 EDT: second AVP session starts right before OOM

A second AVP session started immediately before the OOM:

```text
plex-avp-22A6DB39-FCD0-435A-8486-10CE09FD9148
```

Summary:

- First seen: `Jun 11, 2026 16:03:55.049`
- Last seen before crash: `Jun 11, 2026 16:03:59.360`
- Lines associated: 90
- Transcode session starts: 1
- Plex Transcoder jobs: 1
- Same media file: `Example Show - S02E02 - Example Episode WEBRip-2160p.mkv`
- Max live request count observed: 139
- Segment GETs: 2
- Stream detail lines: 60

Representative redacted log excerpts:

```text
Jun 11, 2026 16:03:56.405 ... Starting a transcode session plex-avp-22A6DB39-FCD0-435A-8486-10CE09FD9148 at offset -1.0
Jun 11, 2026 16:03:56.406 ... hardware transcoding: enabled, but no hardware decode accelerator found
Jun 11, 2026 16:03:56.407 ... Using local file path instead of URL: /data/tv/Example Show/Season 2/Example Show - S02E02 - Example Episode WEBRip-2160p.mkv
Jun 11, 2026 16:03:56.412 ... Job running: ... "Plex Transcoder" -codec:0 hevc -codec:1 eac3_eae ... -ss 2403 ... -codec:0 libx264 ... -codec:1 aac ...
Jun 11, 2026 16:03:56.445 ... Jobs: Starting child process with pid 4542
Jun 11, 2026 16:03:56.922 ... Started session successfully: plex-avp-22A6DB39-FCD0-435A-8486-10CE09FD9148
Jun 11, 2026 16:03:57.349 ... Asked for segment 2403 from session.
Jun 11, 2026 16:03:59.360 ... Asked for segment 2403 from session.
```

### 16:04:00 EDT: kernel OOM kill

The node kernel recorded a pod/cgroup OOM, not host memory exhaustion.

Important lines from earlier inspection:

```text
memory: usage 8388596kB, limit 8388608kB
oom-kill:constraint=CONSTRAINT_MEMCG ... oom_memcg=/kubepods.slice/...pod13d100f0...
Memory cgroup out of memory: Killed process ... (Plex Transcoder) ... oom_score_adj:932
```

The process list in the kernel OOM dump included many Plex transcoders and `av:hevc:*` workers. The OOM victim was one Plex Transcoder, and then the cgroup killed additional Plex/container supervisor processes. Kubernetes reported the Plex container as `OOMKilled` with exit code 137.

## Interpretation / hypothesis

Most likely failure mode:

1. The VisionPlex/AVP client requests HLS playback for a HEVC/EAC3 MKV.
2. Plex cannot direct play/remux with the presented client profile/settings.
3. Plex falls back to HEVC -> H.264 and EAC3 -> AAC transcoding.
4. Hardware transcoding is not actually used for this path, so CPU/software transcode workers are spawned.
5. The client experiences buffering/stall/seek/retry behavior.
6. Instead of a single stable transcode session, Plex sees repeated transcode session starts for the same `plex-avp-*` session and same media at many offsets.
7. Old transcoders do not exit quickly enough, or are not being explicitly torn down by the client/app behavior.
8. A second AVP session starts near the same playback point while the previous runaway session still has remaining work.
9. Plex accumulates many transcoders and segment/progress requests.
10. The Plex pod reaches its 8Gi memory limit and is OOM-killed.

This looks like an app-side playback/retry/session-lifecycle bug more than a general Plex or Kubernetes problem.

## Things to inspect in VisionPlex

Search for where the app constructs Plex playback URLs and transcode session IDs. Key questions:

1. Does the app generate a new `plex-avp-*` session ID on every retry, buffer event, player reload, or seek?
2. Does the app create multiple `AVPlayer`, `AVPlayerItem`, or stream loader instances without releasing the old one?
3. Does retry logic call the Plex playback decision/transcode URL repeatedly without idempotency?
4. On buffering/failure, does the app retry immediately and repeatedly without exponential backoff?
5. Does a seek issue multiple overlapping HLS manifest/segment requests?
6. Does the app request HLS even when AVP could direct play HEVC in MP4/MOV or direct stream/remux?
7. Is the Plex client profile too restrictive, causing Plex to conclude `no direct play video profile exists for http/mkv/hevc/eac3`?
8. Does the app explicitly stop/close the old Plex transcode session before creating a new one?
9. Is the app setting bandwidth/quality limits that force 4K HEVC down to 1080p H.264?
10. Is it using a unique `X-Plex-Client-Identifier` consistently, or generating a new identity too often?

## Suggested instrumentation for next debugging pass

Add client-side logging around playback lifecycle. Include a stable playback attempt ID and stable Plex transcode session ID, but do not log Plex tokens.

Recommended fields:

- `playbackAttemptId`
- `plexSessionId` / transcode session ID (`plex-avp-*`)
- media ratingKey / metadata ID
- selected part ID
- selected media path/container/video/audio if known
- requested playback protocol (`hls`, direct play, direct stream)
- playback URL type: decision, manifest, segment, timeline, stop
- current seek offset
- reason for creating a new player/session:
  - initial play
  - retry after error
  - buffer timeout
  - user seek
  - automatic seek
  - app foreground/background
  - player item replacement
- retry count and backoff delay
- AVPlayer status transitions
- AVPlayerItem error/log events
- whether old player/session was stopped before creating new one

Example log events to add:

```text
PlaybackStart attempt=<uuid> session=<plex-avp-id> ratingKey=<id> reason=initial offset=<sec>
PlaybackDecision attempt=<uuid> session=<plex-avp-id> protocol=<hls/direct> quality=<...>
PlayerItemCreated attempt=<uuid> session=<plex-avp-id> urlType=manifest
BufferingStarted attempt=<uuid> session=<plex-avp-id> offset=<sec>
RetryScheduled attempt=<uuid> session=<plex-avp-id> retry=<n> delayMs=<ms> reason=<...>
RetryCanceled attempt=<uuid> oldSession=<plex-avp-id> reason=<...>
TranscodeSessionStop attempt=<uuid> session=<plex-avp-id> reason=<new_attempt/deinit/user_stop/error>
PlayerDeinit attempt=<uuid> session=<plex-avp-id>
```

## Suggested behavioral fixes to test

Start app-side before changing Kubernetes/Plex limits.

1. Enforce exactly one active Plex playback/transcode session per playback attempt.
2. Reuse the same transcode session across transient buffering/segment retries.
3. Do not create a new `plex-avp-*` session ID unless the old one is explicitly stopped or the user starts a separate playback.
4. Add exponential backoff and max retry limits for manifest/segment retry loops.
5. Debounce seeks. Do not fire many overlapping seek-induced manifest requests.
6. On retry or player replacement, explicitly stop the old session if Plex API supports it for the path being used.
7. Prefer direct play/direct stream where possible. Avoid forcing HLS transcode for HEVC if AVP can handle the stream/container or if remuxing is enough.
8. Adjust the Plex client profile / playback parameters to advertise HEVC/EAC3 capabilities more accurately, if valid for Vision Pro.
9. Consider lowering default quality or avoiding high bitrate 4K HEVC transcode until session lifecycle is fixed.
10. Add a guard: if retry count exceeds threshold, show an error instead of spawning more playback sessions.

## Useful commands used during triage

From the cluster-management workstation:

```bash
kubectl -n media get pod -l app.kubernetes.io/name=plex -o wide
kubectl -n media top pod -l app.kubernetes.io/name=plex
kubectl -n media get pod -l app.kubernetes.io/name=plex -o json | jq '.items[] | {pod:.metadata.name,node:.spec.nodeName,qos:.status.qosClass,phase:.status.phase, containerStatuses:[.status.containerStatuses[] | {name, restartCount, state, lastState, ready}]}'

pod=$(kubectl -n media get pod -l app.kubernetes.io/name=plex -o jsonpath='{.items[0].metadata.name}')
kubectl -n media exec "$pod" -- sh -lc 'ps -eo pid,ppid,user,comm,rss,vsz,args | grep -Ei "Plex Transcoder|Plex Media Serv|EasyAudioEncode|dmx0|chapter|thumb" | grep -v grep || true'

node=$(kubectl -n media get pod -l app.kubernetes.io/name=plex -o jsonpath='{.items[0].spec.nodeName}')
kubectl top node "$node"
kubectl describe node "$node" | sed -n '/Conditions:/,/Addresses:/p'

ssh admin@k8s-02 "sudo journalctl -k --since '2 hours ago' --no-pager | grep -Ei 'out of memory|oom-kill|Killed process|Plex|memory cgroup' | tail -80 || true"
```

Plex app logs inside the pod:

```bash
pod=$(kubectl -n media get pod -l app.kubernetes.io/name=plex -o jsonpath='{.items[0].metadata.name}')
kubectl -n media exec "$pod" -- sh -lc 'logdir="/config/Library/Application Support/Plex Media Server/Logs"; ls -lt "$logdir" | sed -n "1,40p"'
```

Important: Plex logs can contain tokens/account details. Redact before sharing.

## Cautions

- Do not blindly raise the Plex pod memory limit as the first fix. That may only delay the OOM and allow even more runaway transcoders.
- Do not rely only on Loki for this issue. Loki had container stdout and restart evidence, but the richest causal trail was in Plex's persisted app logs under the config volume.
- The logs contain Plex tokens and user/account identifiers in raw form. Do not paste raw logs into issues/agents without redaction.
- The report above intentionally redacts tokens/account identifiers and classifies internal IPs instead of preserving exact request sources.

## Bottom line for next agent

Investigate VisionPlex playback session lifecycle and retry behavior. The Plex server evidence shows repeated `plex-avp-*` HLS transcode jobs for the same HEVC/EAC3 media item within seconds, no usable hardware transcode path, and a resulting 8Gi Plex pod OOM. The likely bug is that buffering/retry/seek logic creates overlapping Plex transcode sessions instead of reusing or cleaning up the existing session.
