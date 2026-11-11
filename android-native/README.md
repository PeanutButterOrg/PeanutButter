# PeanutButter Native Android

Leanback **TV** app + Material **phone companion**, sharing one GraphQL core.
Flutter (`frontend/`) stays the desktop / multi-platform client.

## Modules

| Module | Package | Role |
|--------|---------|------|
| `:core` | `app.peanutbutter.core` | Session, LAN discovery, GraphQL API |
| `:tv` | `app.peanutbutter.tv` | AndroidX Leanback browse + LibVLC SurfaceView player |
| `:phone` | `app.peanutbutter.phone` | Phone companion (home grid, stream, ExoPlayer) |

## Build

```bash
cd android-native
./gradlew :tv:assembleAppDebug :tv:assembleLauncherDebug :phone:assembleDebug
```

The TV module has two flavors from the same code:

| Flavor | App id | Name | |
|---|---|---|---|
| `app` | `app.peanutbutter.tv` | PeanutButter TV | normal app in the TV's app row |
| `launcher` | `app.peanutbutter.tv.launcher` | PeanutButter Launcher | the TV's Home screen: PeanutButter, your apps, inputs and quick settings — see [tv/src/launcher/README.md](tv/src/launcher/README.md) |

Both can be installed side by side; each self-updates only to its own APK.

Install on BeyondTV / phone:

```bash
adb install -r tv/build/outputs/apk/app/debug/tv-app-universal-debug.apk
adb install -r tv/build/outputs/apk/launcher/debug/tv-launcher-universal-debug.apk
adb install -r phone/build/outputs/apk/debug/phone-debug.apk
```

## Pairing

Same as Flutter: enter the **6-digit code** from the server console, optionally **Find server on LAN**.

## UX parity (v1)

- Home rows: Continue watching · Trending · Popular · Newly added (dark canvas `#0E0E12`, accent `#5B9FFF`)
- Detail → Stream (Jackett via backend) → play
- TV: D-pad play/pause, ←/→ ±10s, Soft LibVLC decode
- Phone: touch grid + ExoPlayer

Next: series seasons/episodes picker, search, favourites, local libtorrent on-device (same as Flutter).
