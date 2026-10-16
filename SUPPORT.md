# Labstream — Support

Labstream is a native Apple-platform client for **your own Plex Media Server, Jellyfin server, or Emby server**.

The repository contains pre-release targets for Apple Vision Pro, iPhone/iPad, Apple TV, and Mac.
That source coverage does not by itself assert availability in any binary distribution channel;
there is no public App Store release yet. Platform-specific status and acceptance gates are in the
[release guide](https://github.com/jlipworth/Labstream/blob/main/docs/RELEASES.md),
[Mac target guide](https://github.com/jlipworth/Labstream/blob/main/docs/MACOS.md), and
[tvOS target guide](https://github.com/jlipworth/Labstream/blob/main/docs/TVOS.md).

## Requirements

- Apple Vision Pro running **visionOS 26.0** or later; an iPhone/iPad running **iOS/iPadOS 26.1**
  or later; Apple TV running **tvOS 26** or later; or an Apple-silicon Mac running **macOS 26**.
- A reachable **Plex Media Server**, **Jellyfin server**, or **Emby server** you administer or have access to.
  Plex mode uses a Plex account for PIN/OAuth sign-in; Jellyfin supports a server URL with a
  username (password optional) or Quick Connect; Emby supports an Emby Connect PIN or a manual
  server URL with username/password.
- The app does not bundle or sell media. A separate optional project-operated review/demo
  service hosts licensed sample content; normal use needs no Labstream-operated server. Playback and offline
  downloads are for media you are authorized to access on the server you choose.
- Local-network playback is free. Under Plex's current
  [remote playback requirements](https://support.plex.tv/articles/requirements-for-remote-playback-of-personal-media/),
  remote (off-LAN) **video** streaming can require
  Plex Pass or Remote Watch Pass on your account, or Plex Pass on the server owner's
  account. This is a Plex service policy, not a Labstream feature.

## Getting started

1. Launch Labstream and choose Plex, Jellyfin, or Emby.
2. Sign in to the selected backend and choose/enter the server.
3. Browse your libraries, then play. Titles resume where you left off.

Every option on the Settings screen, with its default and the platforms that show it, is described
in the [Settings reference](https://github.com/jlipworth/Labstream/blob/main/docs/SETTINGS.md).

## Common questions

- **A reinstall asks me to sign in again.** A normal upgrade install usually preserves app state.
  Deleting Labstream, erasing the simulator/device, or replacing a distribution build with a
  development build can reset the app container and selected-session state. Canonical credentials
  are Keychain-backed, but availability can still differ by identity, device, and Keychain state,
  so a fresh sign-in may be required.
- **Playback failed / spinner won't clear.** Labstream has a stall watchdog
  that can attempt a bounded recovery and otherwise surfaces a **Playback failed** / Retry overlay.
  Choosing Retry rebuilds the player. If the problem persists, confirm the server is reachable and
  try a lower streaming quality in Settings (see the
  [Settings reference](https://github.com/jlipworth/Labstream/blob/main/docs/SETTINGS.md)).
- **Can I watch away from home?** Remote Plex video can require Plex Pass / Remote Watch
  Pass on your account, or Plex Pass on the server owner's account (a Plex policy).
  Jellyfin and Emby remote access depend on your server/network setup.

## Reporting a problem

Search [existing issues](https://github.com/jlipworth/Labstream/issues?q=is%3Aissue) first; if one
matches, add your details there. Otherwise use the
[bug report form](https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml).
Include steps to reproduce, your device type (Apple Vision Pro, iPhone, iPad, Apple TV, or Mac),
OS version, backend (Plex, Jellyfin, or Emby), and the app version and build from the **About**
section of Settings. Ideas belong in
[Discussions ▸ Ideas](https://github.com/jlipworth/Labstream/discussions/categories/ideas) and
questions in [Discussions ▸ Q&A](https://github.com/jlipworth/Labstream/discussions/categories/q-a).

For hard-to-reproduce issues, turn on **Settings ▸ Diagnostics ▸ Enable diagnostic logging**,
reproduce the problem once, then tap **Send feedback to developer**. The report is redacted before
you see it (no tokens, hostnames, usernames, paths, or media titles); review it before sharing. The
[bug reporting guide](https://github.com/jlipworth/Labstream/blob/main/docs/REPORTING-BUGS.md)
has the full steps, per-platform options, and what the report does and does not include.

## Privacy

See the [Privacy Policy](https://github.com/jlipworth/Labstream/blob/main/PRIVACY.md). Labstream does
not automatically upload app analytics or diagnostic reports. The optional project-operated
review/demo server receives and retains operational data when you select it; see the policy for
server records, resets and unresolved retention limits. Optional
diagnostic reports stay local unless you choose to copy, export, share, or open a GitHub issue;
ordinary playback progress and other backend operations may still be sent to the media server you
selected.
