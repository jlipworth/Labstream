---
name: deploy-to-device
description: Build and install Labstream onto a physical Apple Vision Pro over Wi-Fi for on-device testing (NOT the simulator). Use whenever the user asks to load / deploy / install / sideload / "put it on the headset" / test the app on the real Vision Pro. Covers device signing (the team-ID OU trap), the one-command deploy script, provisioning-profile expiry, and how the Xcode-loaded build coexists with the App Store build.
---

# Deploy Labstream to a physical Apple Vision Pro

This is **on-device** install over Wi-Fi via `devicectl` — a different path from the
simulator loop in `CLAUDE.md` (`simctl` + `$SIMID`). A device build lands in
`Debug-xros` (not `Debug-xrsimulator`) and **must be code-signed** (no
`CODE_SIGNING_ALLOWED=NO`). The whole flow is wrapped in one script so the signing
traps below never have to be re-derived.

## TL;DR — one command

```sh
scripts/deploy-to-device.sh            # build (signed) + install to the paired Vision Pro
scripts/deploy-to-device.sh --launch   # also launch it (headset must be awake/worn)
scripts/deploy-to-device.sh --no-build # reinstall the last device build without rebuilding
scripts/deploy-to-device.sh --verbose  # show full device/team IDs instead of masked IDs
```

The script auto-derives the device UUID (from `devicectl list devices`) and the signing
team (from the cert OU — see trap #1). Override with `VP_DEVICE_ID` / `VP_DEVELOPMENT_TEAM`
only if you have several devices or teams. By default it masks device/team IDs in output;
`--verbose` / `--full-ids` prints them in full for private debugging.

## Prerequisites (one-time, GUI — the agent cannot do these headlessly)

1. **Pair the Vision Pro.** It must show as `available (paired)` in
   `xcrun devicectl list devices`. Same Wi-Fi network as the Mac. First-time pairing is
   done through Xcode (Window ▸ Devices and Simulators) and requires the headset to trust
   the Mac.
2. **Sign an Apple ID into Xcode.** Xcode ▸ Settings (⌘,) ▸ **Accounts** ▸ **+** ▸ Apple ID.
   The keychain having an "Apple Development" cert is **not** enough — automatic
   provisioning also needs the Apple ID logged in here to mint/refresh the device
   profile. Without it the build fails with **`No Account for Team … / No profiles for
   'com.jlipworth.Labstream' were found`**. A free/personal Apple ID works (see expiry
   below); a paid Developer Program membership works too and lasts a year.

## The two traps this script exists to dodge

### Trap 1 — DEVELOPMENT_TEAM is the cert **OU**, not the CN parenthetical
The keychain identity prints as
`Apple Development: …@… (YYYYYYYYYY)` — but `YYYYYYYYYY` is a **per-cert id, not the
team**. The real team is the certificate's **OU** field:

```sh
security find-certificate -a -c "Apple Development" -p \
  | openssl x509 -noout -subject
# subject= … CN=Apple Development: …@… (YYYYYYYYYY), OU=XXXXXXXXXX, O=<Your Name>, C=US
#                                     ^^ NOT the team                ^^^^^^^^^^ THE TEAM
```

Passing the parenthetical as `DEVELOPMENT_TEAM` → `error: No Account for Team
"YYYYYYYYYY"`. Use `OU` → **`XXXXXXXXXX`**. The script reads the OU automatically; if you
ever build by hand, pass `DEVELOPMENT_TEAM=XXXXXXXXXX -allowProvisioningUpdates`.
*This is the thing that "keeps getting flagged in some sessions" — now solved in one place.*

### Trap 2 — it's a device build, signed, no simulator shortcuts
`-destination 'platform=visionOS,id=<UUID>'` (device), product in `Debug-xros`, real
signing required. The LINK-SKIP trap from `CLAUDE.md` still applies — the script deletes
the `Debug-xros/Labstream.app` before building so a skipped `Ld` step can't leave a stale
binary, stamps the internal Build ID via `scripts/build-version-args.sh`, and verifies the
built `TeamIdentifier` after.

## Manual build (only if the script can't be used)

```sh
DEVICE_ID=$(xcrun devicectl list devices | grep -iE 'vision|reality' \
  | grep -oiE '[0-9a-f-]{36}' | head -1)
rm -rf "$HOME/Library/Developer/Xcode/DerivedData/Labstream-"*/Build/Products/Debug-xros/Labstream.app
VERSION_ARGS=()
while IFS= read -r arg; do VERSION_ARGS+=("$arg"); done < <(scripts/build-version-args.sh)
xcodebuild "${VERSION_ARGS[@]}" -project Labstream.xcodeproj -scheme Labstream \
  -destination "platform=visionOS,id=$DEVICE_ID" \
  -configuration Debug -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=XXXXXXXXXX build
APP=$(/bin/ls -td "$HOME/Library/Developer/Xcode/DerivedData/Labstream-"*/Build/Products/Debug-xros/Labstream.app | head -1)
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
```

## Provisioning-profile expiry (free-team gotcha)

A free/personal Apple-ID profile expires **~7 days** after signing (a paid membership
lasts a year). Inspect it:

```sh
security cms -D -i ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
  | plutil -extract ExpirationDate raw -
```

When it lapses the installed app refuses to launch ("Unable to verify app"). Fix =
just re-run `scripts/deploy-to-device.sh` (a fresh `-allowProvisioningUpdates` build mints
a new profile). Free teams also cap the number of distinct App IDs and devices — reusing
the one `com.jlipworth.Labstream` bundle id keeps us well under it.

## Coexistence: Xcode-loaded build vs. App Store build

The dev build and a future App Store ("consumer") build **share one bundle id**
(`com.jlipworth.Labstream`). visionOS keys an installed app by bundle id, so:

- **Only one can be installed at a time.** Installing the dev build **replaces** an App
  Store copy (and its data container), and vice-versa. They are different *signers*
  (personal dev cert vs. App Store), so visionOS may reject installing one straight over
  the other — if `devicectl install` errors with a signing/verification mismatch, delete
  the existing app on the headset first, then re-run the deploy.
- **Today this is fine** — we only run the Xcode-loaded build on-device, so the collision
  is moot. Just be aware the dev install clobbers App Store state and login.
- **When we need both side-by-side** (e.g. compare consumer vs. dev), the dev build needs
  its **own** bundle id + display name — `com.jlipworth.Labstream.dev` /
  "Labstream (Dev)" via a Debug-only `PRODUCT_BUNDLE_IDENTIFIER` suffix and
  `PRODUCT_NAME`. Not implemented yet (the user deferred it); when asked, add a
  `.dev` suffix in the Debug config and a Settings-bundle/`CFBundleDisplayName` marker so
  the two are visually distinguishable on the Home View. Note Plex/Jellyfin/Emby logins
  live in the Keychain keyed per-build, so a separate bundle id = separate logins.

## Verify it actually deployed

`devicectl ... install app` prints `App installed:` with the `installationURL` on success.
For a runtime check, `--launch` (headset must be awake/worn). Reading on-device logs is
heavier than the sim (`log` over the device tunnel / Console.app); for functional testing
the user drives the headset directly. A clean install + the app launching to the browse
UI on the headset is the close-out for a device deploy.

## Codex / cross-agent note

Codex picks this up via `AGENTS.md` (which points here). The script is the portable
surface — both Claude and Codex should call `scripts/deploy-to-device.sh` rather than
re-deriving signing. Keep the script as the single source of truth; if the team id,
device, or bundle-id strategy changes, update the script + this file together.
