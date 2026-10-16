# Settings reference

This page describes every option on Labstream's **Settings** screen, in the order the screen shows
them. On Apple Vision Pro, iPhone, iPad, and Apple TV, Settings is a tab in the app; on Mac it opens
in the standard Settings window (**Labstream ▸ Settings…**).

Platform column key: **Vision** = Apple Vision Pro, **iOS** = iPhone and iPad, **TV** = Apple TV,
**Mac** = Mac. "All" means every platform.

Your choices are stored on this device only. They are not synced between devices and are not sent
to Labstream's developer. Sign-in credentials are stored separately in the Keychain (see the
[Privacy policy](privacy.md)).

## Backend

| Setting | What it does | Default | Platforms |
| --- | --- | --- | --- |
| **Media Backend** (Plex / Jellyfin / Emby) | Switches which kind of server Labstream uses. Each backend keeps its own sign-in, so switching back reconnects automatically if you were already signed in; otherwise the sign-in flow opens. | The backend you first signed in with | All |

## Server

What appears here depends on the active backend.

| Setting | What it does | Backend | Platforms |
| --- | --- | --- | --- |
| **Plex Server** | Chooses which of your Plex account's servers to browse and play from. Name, version, and connection details for the selected server are shown below it. | Plex | All |
| **Check server reachability** | Tests each discovered Plex server once and marks it Reachable or Unreachable. Nothing is checked in the background. | Plex | All |
| **Re-discover servers** | Refreshes the list of servers available to your Plex account. | Plex | All |
| **Sign in to a different Jellyfin server** / **Sign in to a different Emby server** | Signs out of the current server (after confirmation) so you can connect to another one. | Jellyfin, Emby | All |

## Libraries

| Setting | What it does | Default | Platforms |
| --- | --- | --- | --- |
| **Choose Libraries** | Picks which libraries appear on the Libraries screen. Choices are saved separately for each backend, and new libraries added on the server appear automatically. | All libraries shown | All |

## Playback

| Setting | What it does | Default | Platforms |
| --- | --- | --- | --- |
| **Home / Local Quality** | Maximum video quality when the selected Plex connection is local to your network. **Original (Direct Stream)** plays the source video without re-encoding when possible; **Maximum (Transcode)** asks the server to re-encode at the highest quality; the numbered choices (2 Mbps · 720p through 40 Mbps · 4K) cap the bitrate. | Original (Direct Stream) | All |
| **Internet / Remote Quality** | The same choices, applied when the Plex connection is remote. Jellyfin and Emby currently always use this setting. | 8 Mbps · 1080p | All |
| **Auto Play Up Next** | When a TV episode ends, automatically starts the next one. Up Next is currently available for Plex episodes. | On | All |
| **Up Next Countdown** | How long the Up Next card counts down before playing the next episode: Immediate, 5s, 10s, 15s, 30s, or 60s. Unavailable when Auto Play Up Next is off. | 10s | All |
| **Rewind on Resume** | When you resume a partly watched title, starts this many seconds earlier than where you stopped: None, 5s, 10s, 15s, 30s, or 60s. | None | All |
| **Skip Intro** | **Disabled** hides the Skip Intro button, **Manual** shows it, and **Automatic** skips the intro for you. Requires intro markers, which only Plex provides. | Manual | All |
| **Skip Credits** | Same choices as Skip Intro, for end credits. Plex only. | Manual | All |
| **Adaptive Bitrate** | If playback keeps stalling, Labstream may reopen the stream at a lower quality, and step back up after a period of healthy playback. It never goes above your quality setting. | Off | All |
| **Dolby Vision Signalling (Experimental)** | Tells the server this device can play Dolby Vision, so Dolby Vision titles may be sent without conversion. Experimental; turn it off if Dolby Vision titles look wrong or fail to play. | Off | All |
| **Show Media in Spotlight & Siri** | Lets titles you browse appear in system search, Siri, and Shortcuts suggestions. Turning it off stops new suggestions and clears Labstream's existing Spotlight entries. | On | All |
| **Preferred Audio** | Audio language to pick automatically when a title has more than one: System Default or a specific language. | System Default | All |
| **Preferred Subtitles** | Subtitle language to pick when subtitles are turned on automatically (see the next row). | System Default | All |
| **Auto-select Subtitles** | **Manually Selected**: subtitles stay off until you choose them in the player. **Shown with Foreign Audio**: subtitles turn on when the audio isn't in your preferred audio language. **Always Enabled**: subtitles turn on whenever your preferred subtitle language is available. | Manually Selected | All |
| **Burn Subtitles** | Controls whether subtitles are drawn into the video by the server. **Automatic** lets Plex decide; **Only Image Formats** burns image-based subtitles (such as PGS or VobSub); **Always** burns the selected subtitle. Burning applies only when subtitles are auto-selected and requires the server to re-encode the video; at Original quality Labstream asks before re-encoding. Plex only. | Automatic | All |

The footer under this section shows which quality cap is currently in effect.

## Downloads

Apple TV is streaming-only, so this section does not appear there.

| Setting | What it does | Default | Platforms |
| --- | --- | --- | --- |
| **Default Quality** | Quality preselected for new downloads: Original when available, Original video quality, or a fixed preset from 4K 40 Mbps down to 480p 1.5 Mbps. Original is offered only when the server can provide it. | 1080p 8 Mbps | Vision, iOS, Mac |
| **Storage Limit** | Maximum space downloads may use: Unlimited, 10 GB, 25 GB, 50 GB, 100 GB, or 250 GB. A new download that would exceed the limit is refused; existing downloads are never deleted automatically. | Unlimited | Vision, iOS, Mac |
| **Use cellular data for downloads** | Allows new downloads to use cellular data on devices that have it. Transfers already in progress keep their previous setting. | Off | Vision, iOS, Mac |
| **Queue Order** | **Respect server queue order** or **Prioritize quick downloads**. Prioritizing moves a new Plex server-side conversion ahead of other waiting conversions (never ahead of the one already running), when your Plex account is allowed to. Jellyfin and Emby are unaffected. | Respect server queue order | Vision, iOS, Mac |
| **Items** / **Storage used** | Shows how many downloads are on this device and how much space they use. | — | Vision, iOS, Mac |
| **Remove completed downloads** | Deletes finished downloads from this device (after confirmation). | — | Vision, iOS, Mac |
| **Remove all downloads** | Cancels active transfers and deletes every download from this device (after confirmation). | — | Vision, iOS, Mac |

## Maintenance

| Setting | What it does | Platforms |
| --- | --- | --- |
| **Clear image cache** | Deletes cached artwork. Artwork downloads again the next time it appears. | All |
| **Clear Spotlight search results** | Removes Labstream titles from system search. Browsing Home or library pages again adds them back while **Show Media in Spotlight & Siri** is on. | Vision, iOS, Mac |

## Diagnostics

| Setting | What it does | Default | Platforms |
| --- | --- | --- | --- |
| **Enable diagnostic logging** | Keeps a small, redacted log of app events on this device to help investigate a problem. Nothing is uploaded automatically. | Off | All |
| **Copy diagnostic report** | Copies a redacted report to the clipboard. | — | Vision, iOS, Mac |
| **Export diagnostic report file** | Saves the redacted report as a text file. | — | Vision, iOS, Mac |
| **Send feedback to developer** | Opens a preview of the redacted report that you can share or attach to a GitHub bug report. | — | All |

Reports leave out sensitive values such as sign-in tokens, server addresses, usernames, file paths,
and media titles. See "Reporting a problem" in [Support and troubleshooting](support.md) for the
full reporting steps.

## About

Shows the app **Version**, **Build**, build ID and date, operating system version, and the client
name Labstream reports to your server. Include the version and build when reporting a problem.

## Account

| Setting | What it does | Backend | Platforms |
| --- | --- | --- | --- |
| **Signed In As** / **Username** | The Plex account currently signed in. | Plex | All |
| **Refresh account identity** | Reloads your Plex account name and details. | Plex | All |
| **Reset playback preferences** | Clears the playback speed, video fit/fill mode, and audio/subtitle language choices Labstream remembers from the player. Quality, Up Next, skip, and download settings are not changed. | All | All |
| **Sign Out of** *backend* | Signs out of the active backend (after confirmation). You will need to sign in again to use it. | All | All |
| **Sign Out of All Backends** | Appears when you are signed in to more than one backend. Signs out of all of them. Downloaded media stays on the device and can be played again after you sign back in. | All | All |
