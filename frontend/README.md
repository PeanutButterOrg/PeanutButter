# PeanutButter Frontend

Flutter client for [PeanutButter](https://github.com/PeanutButterOrg/PeanutButter) — browse catalog, play local library files, and stream Jackett magnets on-device.

## Supported platforms

| Platform | Playback | On-device torrents |
| --- | --- | --- |
| Linux / Windows / macOS | media_kit (libmpv) | yes (libtorrent) |
| Web | media_kit (browser `<video>`) | no — `local_torrent_web.dart` stub |

Android TV is **not** built from this project any more — it is the native
Leanback app in [`../android-native`](../android-native/README.md).

Device-specific behavior is selected through `lib/platform/` (`DeviceProfile`, `StreamSeekController`, input policy). Prefer those APIs over raw `Platform.isX` checks.
Some `tv_*` helpers are still used for desktop keyboard navigation (arrow keys / Esc).

## Setup

```bash
cd frontend
flutter pub get
```

Optional: copy repo-root `.env` for desktop discovery defaults (not required when pairing against a remote server).

## Run

```bash
flutter run -d linux
flutter run -d macos
flutter run -d windows
flutter run -d chrome
```

## Pairing

1. Open the server console (`http://SERVER:3001/`) and sign in
2. Create a device code
3. In the app: set server URL (or **Discover on LAN**) → enter the 6-digit code

Discovery probes the saved URL, the router/gateway, common hosts on each LAN subnet (full /24 sweep on desktop) on port 3001. (There is no mDNS discovery yet.)

## Streaming notes

- Torrents are handled by **libtorrent_flutter** on the device (not the API)
- Scrub / ±10s seeks on streams **debounce 3 seconds**, then Range-retarget the download window and seek the player

## Desktop CI packages

Produced by [Platform Builds](../.github/workflows/desktop-builds.yml)
(raw deliverables after one Actions download unwrap — not nested zips):

- Linux: portable `PeanutButter/` folder, `.deb`, AppImage
- Windows: portable `PeanutButter/` folder, Inno Setup `.exe`
- macOS: universal `PeanutButter.app`

Local Linux packaging helper: `../scripts/package-linux.sh` / `../scripts/build-desktop-docker.sh`.

## Tests

```bash
flutter test
dart analyze lib
```

## Project layout (high level)

```
lib/
  platform/          # DeviceProfile, seek settle, input policy
  screens/           # home, catalog, detail, player, settings, pairing, …
  local_torrent.dart # picks local_torrent_io.dart (FFI) or local_torrent_web.dart
```
