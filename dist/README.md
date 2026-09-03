# Desktop & TV installs

Built packages land in this folder when you run the build scripts (or CI).

**Backend (server) install:** see [INSTALL-SERVER.md](INSTALL-SERVER.md) or the full guide [`docs/SERVER.md`](../docs/SERVER.md).

## Already built on this Linux machine

| File | Device |
| --- | --- |
| `PeanutButter-linux-x64.zip` | Any Linux x64 PC |
| `PeanutButter-tv.apk` | Android TV |
| `INSTALL-SERVER.md` | How to run the API on your homelab / VPS |

### Linux PC (this machine)

Already installed to `~/.local/opt/peanutbutter`. Launch with:

```bash
peanutbutter
```

Or unzip `PeanutButter-linux-x64.zip` elsewhere and run `./run.sh`.

### Android TV

```bash
adb install -r PeanutButter-tv.apk
```

## Windows & macOS (build on that OS)

Flutter **cannot** cross-compile Windows/macOS apps from Linux. Use one of:

1. **GitHub Actions** — push this repo, then run workflow **Desktop builds** (Actions → Desktop builds → Run workflow). Download the Windows / macOS zip artifacts.
2. **On a Windows PC**

```powershell
cd PeanutButter
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
```

Unzip `dist\PeanutButter-windows-x64.zip` and run `peanutbutter.exe`.

3. **On a Mac**

```bash
cd PeanutButter
./scripts/build-desktop.sh
```

Open `dist/PeanutButter-macos.zip` and launch the `.app` (may need right-click → Open the first time).

Windows/macOS platform folders are already in `frontend/windows` and `frontend/macos`.
