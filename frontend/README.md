# PeanutButter for desktop

The [PeanutButter](../README.md) app for **Windows, macOS and Linux**, built with Flutter. It's also built for the web for a quick look in a browser (no torrents there).

Android TV has its own native app: see [android-native](../android-native/README.md).

---

## Features

- **Home:** a hero banner, then Continue watching, Trending, Popular and Recently added, with streaming-service logos on posters.
- **Browse:** Movies and Series with filters (genre, year, rating, streaming service) and typo-tolerant search.
- **Title pages:** trailer, scores, seasons and episodes, the source picker, favourite and watched, and **Notify me** for new episodes.
- **Player (libmpv via media_kit):**
  - Skip intro, Skip credits, and **Play next** with a countdown.
  - Subtitles from OpenSubtitles or Wyzie, or your own file or link.
  - Audio tracks.
  - Full keyboard control.
- **On-device torrents:** magnets are downloaded by libtorrent on your computer and played while they download. Seeks move the download straight to the new position.
- **Lists:** Favourites and Watched.
- **Pairing:** finds the server on your network, then you type the 6-digit code.
- **Self-update** from your server, signature-checked, never in the middle of a movie.

| Platform | Player | Torrents | Package |
|---|---|---|---|
| Windows | libmpv | ✅ | Setup `.exe` |
| macOS | libmpv | ✅ | Universal `.app` (Intel + Apple silicon) |
| Linux | libmpv | ✅ | `.deb` or AppImage |
| Web | browser `<video>` | — | Docker image behind nginx (`web` service in `docker-compose.yml`) |

---

## Run it

You need [Flutter](https://docs.flutter.dev/get-started/install) on the stable channel.

```bash
cd frontend
flutter pub get
flutter run -d macos          # or: linux, windows, chrome
```

**Linux** also needs the system libraries CI installs:

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev libmpv-dev mpv libwebkit2gtk-4.1-dev \
  libtorrent-rasterbar-dev libboost-dev libssl-dev
```

Then pair: open the server console, create a device code under **Devices**, and type it in the app.

**Checks** (CI runs both on every release):

```bash
flutter analyze
flutter test
```

---

## Packaging

Release installers are built by the [Platform Builds](../.github/workflows/desktop-builds.yml) workflow on every `v*` tag and attached to the GitHub Release:
- `PeanutButter-windows-x64-setup.exe`
- `PeanutButter-macos-universal.zip`
- `PeanutButter-linux-amd64.deb`
- `PeanutButter-linux-x86_64.AppImage`

Each workflow run also keeps portable Windows and Linux folders as build artifacts.

To build locally:
- **Linux:** `../scripts/package-linux.sh`, or `../scripts/build-desktop-docker.sh` to build inside Docker.
- **Windows:** `../scripts/build-windows.ps1`.
- **Any platform:** `flutter build <platform> --release`.

---

## Project layout

```
lib/
  main.dart               app start, routing, session watch, update checks
  screens/                home, browse, catalog, detail, player, search, settings, pairing, …
  widgets/                posters, hero banner, filter bar, source picker, subtitle import, …
  providers/              Riverpod state: settings and session, catalog data
  graphql/                queries and the schema snapshot (schema.graphql)
  platform/               DeviceProfile, seek handling, input policy: use these instead of Platform.isX
  services/discovery.dart finding the server on the LAN
  local_torrent.dart      on-device torrents (libtorrent FFI; a stub on the web)
  app_updater.dart        update check, download, hash and signature verification
plugins/libtorrent_flutter  vendored libtorrent bindings with a loopback stream server
packages/                   vendored media_kit Android libs
```

### Notes for contributors

- **Device-specific behaviour** goes through `lib/platform/` (`DeviceProfile`), not scattered platform checks.
- **The player** (`screens/player.dart`) owns its teardown order: player first, then torrent. Changing it has crashed Windows before.
- **The schema** in `lib/graphql/schema.graphql` is a snapshot of the server's. Update it when you change the server's GraphQL.
