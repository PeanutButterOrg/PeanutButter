# PeanutButter Frontend

Flutter client for [PeanutButter](https://github.com/PeanutButterOrg/PeanutButter) — browse catalog, play local library files, and stream Jackett magnets on-device.

## Supported platforms

| Platform | Playback |
| --- | --- |
| Linux / Windows / macOS | media_kit (libmpv) |
| Android phone / emulator | ExoPlayer (`video_player`) |
| Android TV (Leanback) | Native LibVLC (Texture + soft decode) |

Device-specific behavior is selected through `lib/platform/` (`DeviceProfile`, `PlaybackBackendFactory`, `StreamSeekController`, TV input policy). Prefer those APIs over raw `Platform.isX` checks.

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
flutter run -d android
```

Android TV:

```bash
flutter build apk --debug   # or --release
adb connect TV_IP:5555
adb install -r build/app/outputs/flutter-apk/app-debug.apk
# Leanback launcher:
adb shell monkey -p app.peanutbutter.peanutbutter -c android.intent.category.LEANBACK_LAUNCHER 1
```

## Pairing

1. Open the server console (`http://SERVER:3001/`) and sign in
2. Create a device code
3. In the app: set server URL (or **Discover on LAN**) → enter the 6-digit code

Discovery probes saved URL, localhost / emulator gateway, LAN subnets, and optional mDNS `_peanutbutter._tcp`.

## Streaming notes

- Torrents are handled by **libtorrent_flutter** on the device (not the API)
- Scrub / ±10s seeks on streams **debounce 3 seconds**, then Range-retarget the download window and seek the player
- Android TV: seed/download HUD shows only while buffering; Skip Intro / Play Next are D-pad focusable; text fields open a fullscreen soft-keyboard screen

## Desktop CI packages

Produced by [Platform Builds](../.github/workflows/desktop-builds.yml):

- Linux: portable zip, `.deb` zip, AppImage zip
- Windows: portable zip, Inno Setup zip
- macOS: universal `.app` zip

Local Linux packaging helper: `../scripts/package-linux.sh` / `../scripts/build-desktop-docker.sh`.

## Tests

```bash
flutter test
dart analyze lib
```

## Project layout (high level)

```
lib/
  platform/          # DeviceProfile, playback factory, seek settle, TV input
  screens/           # home, catalog, detail, player, settings, pairing, …
  android_playback.dart
  local_torrent.dart
android/app/         # NativeVlcPlayer, jniLibs/libmla.so, Leanback manifest
```
