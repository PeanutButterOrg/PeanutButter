# PeanutButter design

One look on every platform: the Android TV app, the TV Launcher, and the desktop app (Windows, macOS, Linux, web).

## Tokens

[`tokens.json`](tokens.json) holds every colour, font, type size, spacing, corner radius, size and animation time. Nothing else defines them.

```bash
python3 scripts/gen-design-tokens.py          # regenerate after editing tokens.json
python3 scripts/gen-design-tokens.py --check  # fails if a generated file is out of date
```

| Generated file | Used by |
|---|---|
| `frontend/lib/design/tokens.g.dart` | Desktop and web (Flutter): `PbColors`, `PbType`, `PbTypeTv`, `PbSpace`, `PbRadius`, `PbSize`, `PbMotion` |
| `android-native/tv/src/main/res/values/pb_tokens.xml` | TV app and Launcher: `@color/pbt_*`, `@dimen/pbt_*`, `@integer/pbt_motion_*` |
| `design/tokens.css` | Previews and docs |

Desktop sizes are logical pixels for a 1440 × 900 window. TV sizes are dp/sp for a 1080p TV (960 × 540 dp), larger so they read from the sofa.

## Rules

- **Peanut amber** (`primary`) marks the one main action on a screen: Play, Save. Active chips use it too.
- **Blue** (`focus`) is keyboard and remote focus everywhere, and links. A focused element gets a 3 px blue ring; on TV it also grows to 1.06×.
- **Green, yellow and red** only ever mean status (healthy, weak, error), never decoration.
- **Posters and the hero show the star score** (★ 8.6 IMDb), as the apps do today. Stream quality (4K, 1080p) appears only in **Choose a stream**, where you pick a copy.
- **Space Grotesk** for names and headings, **Inter** for everything else. Both are bundled with the apps.
- **Desktop hover = TV focus.** A hover preview on desktop is the focused state on TV, so nothing depends on a mouse.
- **No live blur** on TV: gradients are drawn, not blurred, so cheap TV sticks stay smooth.

## UI revamp plan (branch `ui/revamp`)

The new look follows the structure of the example screens we were given (top bar, hero with Play / My List / More info, Top 10 row, sectioned settings), in PeanutButter's own colours and type.

**Decided:**

| | |
|---|---|
| Colours | PeanutButter's own: dark ground, peanut amber, blue focus |
| TV | Keep the native Kotlin app; rebuild its screens to the new design |
| Sign-in | Device pairing only; no email or Google accounts |
| Add-ons | Managed on the server console, not in the apps |
| Profiles | Prepared for now, built later (see below) |
| Live TV, other languages, right-to-left | Not now |

**Phase 0, design system** (this folder): tokens, the generator, and shared components on both platforms, with screenshot tests so TV and desktop can't drift apart.

**Phase 1, new look on existing screens** (no new backend):
- Top bar: Home · Movies · Series · My List · Explore, search, and the device/profile square.
- Home: hero with Play / My List / More info, Top 10 row with outline numbers, new Continue watching cards.
- Title and series pages, source picker, player menus, search, See all, settings in sections, toasts with Undo or Retry, empty states.
- Built for TV, Launcher and desktop together.

**Prepared for profiles:**
- The square at the top right shows this device today and becomes the profile switcher later.
- On the server, per-viewer data (progress, My List, follows) is read and written through one "viewer" (the device today), so profiles can replace it later without changing every screen.

**Phase 2, new features** (each described and agreed before it's built): Explore by genre and decade, More like this, actor pages, search with recent searches and people, "Because you watched…" and "New and rated 7+" rows, subtitle size and style.

**Later, decided separately:** profiles with Kids mode and PINs.
