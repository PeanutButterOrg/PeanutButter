# PeanutButter for Android TV

The native Android TV app for [PeanutButter](../README.md), written in Kotlin and built for the remote. App id `app.peanutbutter.tv`, Gradle flavor `app`.

---

## Features

- **Home:** Continue watching, Trending, Popular and Recently added rows. Badges show the streaming service, favourite, watched and progress.
- **Title pages:** trailer, scores, seasons and episodes, sources, favourite and watched, and **Notify me** for new episodes.
- **Player:**
  - Skip intro and Skip credits, and **Play next** with a countdown.
  - Subtitles from OpenSubtitles or Wyzie, or a link.
  - Audio track picker and aspect modes.
  - D-pad seeking with a time step.
- **On-device torrents:** magnets are downloaded on the TV and played as they arrive, through the engine described below.
- **Search** with the on-screen keyboard or voice.
- **Pairing:** finds the server on your network, then you type the 6-digit code.
- **Self-update** from your server, signature-checked.

---

## Build and install

You need JDK 17, the Android SDK (API 36), and `adb` for installing.

```bash
cd android-native
./gradlew :tv:assembleAppDebug

adb install -r tv/build/outputs/apk/app/debug/tv-app-universal-debug.apk
```

Each build also produces `arm64-v8a`, `armeabi-v7a`, `x86` and `x86_64` APKs, which are smaller than the universal one. From the repo root, `./scripts/update-apps.sh --tv` builds the TV app, installs it and launches it on a connected TV.

**Tests:** `./gradlew :core:testDebugUnitTest`

**Release builds** come from CI on every `v*` tag and are signed with the release keystore. They're published as `PeanutButter-android-tv*.apk`.

---

## How playback works

```
Title page → server lists sources (magnets) → PlayerActivity
   ├─ your own files:  stream from the server's /files/{id} with Range
   └─ magnets:         TorrentService (foreground) → LocalTorrentEngine (libtorrent4j)
                         → StreamHttpServer on 127.0.0.1 → the player
```

- **Torrents run on the TV.** `LocalTorrentEngine` downloads the chosen file in order. `StreamHttpServer` serves it to the player over a loopback-only HTTP server, waiting for each piece as it arrives. A seek moves the download window straight to the new position.
- **Two players:**
  - **ExoPlayer (Media3) with an FFmpeg decoder** is the default.
  - **LibVLC** can be chosen in Settings for files a TV's decoders can't handle.
  - Both sit behind `PlaybackEngine`.
- **Downloaded pieces** stay on disk for a fast resume, or are wiped when you leave if **Clear cache on exit** is on.

---

## Project layout

| Module | Package | What |
|---|---|---|
| `:core` | `app.peanutbutter.core` | Shared by everything: GraphQL client (`ApiClient`), session and pairing (`SessionStore`), LAN discovery, the torrent engine, the loopback stream server, models |
| `:tv` | `app.peanutbutter.tv` | The TV UI (Compose for TV), player, settings and self-update. |
| `:phone` | `app.peanutbutter.phone` | An early phone companion. **Experimental:** not built by CI and not released. |

Key files in `:tv`:

| File | What it does |
|---|---|
| `ui/MainActivity.kt`, `HomeScreen.kt` | Home rows |
| `ui/DetailsActivity.kt` | Title page, sources, episode picker |
| `ui/PairingActivity.kt` | Server discovery and code entry |
| `player/PlayerActivity.kt` | The player: HUD, skip, Play next, subtitles, torrent hand-off |
| `player/TvPlayback.kt`, `VlcPlayback.kt` | ExoPlayer and LibVLC behind `PlaybackEngine` |
| `update/AppUpdater.kt` | Update check, download, hash and signature verification, install |

---

## Troubleshooting

| Problem | Try |
|---|---|
| "Server not reachable" | The TV and server must be on the same network, and `PUBLIC_URL` on the server must be an address the TV can reach (not `localhost`) |
| Pairing code rejected | Codes expire after 15 minutes: create a new one in the console under **Devices** |
| A video plays without picture or stutters | Switch the player to LibVLC in Settings |
| An update won't install ("signature conflict") | A debug build is installed over a release build or vice versa: uninstall first |
| Logs on TVs with logging turned off | Debug builds keep their own log: `adb shell run-as app.peanutbutter.tv cat files/logs/pb-debug.log`. |
