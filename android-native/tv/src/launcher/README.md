# PeanutButter Launcher

A Home screen for Android TV built around PeanutButter. It is the `launcher`
flavor of the `:tv` module: same code base as **PeanutButter TV**, its own app
id (`app.peanutbutter.tv.launcher`), so both can be installed on one TV.

Everything launcher-specific lives in this folder (`tv/src/launcher`), which only
the launcher build compiles. The TV app (`app` flavor) is not changed by it; the
two share `src/main` (title pages, player, search, pairing, settings) as-is.

## What's on the Home screen

**Top bar**

- Clock and date.
- **Home · Movies · Series** tabs. Resting on a tab for a moment opens it; the
  content switches instantly (both feeds are loaded up front).
- A compact control bar. Each button opens a small panel that drops down from it:

| Button | Panel |
|---|---|
| Search | PeanutButter search (or pairing, if no server yet) |
| Inputs | Live TV and the HDMI / AV inputs, each switching straight to that source; a green dot when something is connected |
| Sound | Mute, and the TV's own *Picture and sound* panel |
| Wi‑Fi | Connectivity: network status and Wi‑Fi, the PeanutButter server, Bluetooth (switch, devices connected right now, pair new) |
| Settings | PeanutButter settings and search; the TV's network, remotes, picture and sound, apps, date and time, all settings |

A **red dot** on the Wi‑Fi button means something needs attention: no internet,
the PeanutButter server can't be reached, or Bluetooth is off while you have
paired devices. The Connectivity panel says which (and offers *try again* for
the server).

**Below the top bar**

- **Carousel**: continue watching and trending titles (Home mixes movies and
  series; the Movies / Series tabs show only their own). Rotates every 7 s,
  ◀ ▶ flip it while focused, OK opens the title. Without a server it offers
  *Connect your server*.
- **Your apps** (Home tab): the apps you installed, in your order.
  - Hold **OK** on an app: *Move* (◀ ▶, then OK), *Remove from Your apps*,
    *App info*.
  - **+ Edit** at the end opens a grid of every app on the TV: select to add or
    remove; the numbers set the order. Done or Back saves.
- **Poster rows**: Continue watching, Trending, Popular, Recently added, with
  the same badges as the TV app (streaming service, favourite, watched,
  progress). **See all** at the end of a row opens the full list.

**Remote**

- ◀ ▶ ▲ ▼ move between items and rows; ▲ from the carousel goes to the open tab.
- **Back** goes to the top and focuses the open tab. Home always comes back here.

## Build and install

```bash
cd android-native
./gradlew :tv:assembleLauncherDebug
adb install -r tv/build/outputs/apk/launcher/debug/tv-launcher-universal-debug.apk
```

Release APKs are built by CI on each `v*` tag
(`PeanutButter-android-tv-launcher*.apk`) and offered as updates through the
paired server, like the TV app (update platform `android-tv-launcher`).

## Making it the Home screen

Pick **PeanutButter Launcher** when Android asks for a Home app, or:

```bash
adb shell cmd package set-home-activity app.peanutbutter.tv.launcher/app.peanutbutter.tv.launcher.LauncherActivity
```

Google TV's launcher has a higher-priority Home entry and keeps winning on some
TVs. Turning it off (it stays installed) makes Home open PeanutButter:

```bash
adb shell pm disable-user --user 0 com.google.android.tvlauncher
```

To go back to Google TV:

```bash
adb shell pm enable com.google.android.tvlauncher
```

## Debugging

Some TVs ship with logging switched off. Debug builds keep the last crash in
the app's files:

```bash
adb shell run-as app.peanutbutter.tv.launcher cat files/last-crash.txt
```

## Code map

| File | What it does |
|---|---|
| `LauncherActivity.kt` | The Home screen: header, tabs, control bar, data loading, row-to-row focus |
| `HomeContent.kt` | The scrolling sections (carousel, Your apps, poster rows, See all) |
| `HeroCarousel.kt` | The carousel card |
| `AppsRow.kt`, `AppTileView.kt`, `AppPicker.kt` | Your apps, its tiles and the + Edit grid |
| `ControlPanel.kt`, `TvControls.kt` | The drop-down panels and the TV controls behind them |
| `Motion.kt` | Focus lift, rounded clipping and the small animations |
| `Posters.kt`, `TopCropImageView.kt` | Poster loading / preloading, carousel image crop |
