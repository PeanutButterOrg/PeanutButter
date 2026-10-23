#!/usr/bin/env python3
"""Write manifest.json for a GitHub Release (run by CI on version tags).

    release_manifest.py <release-dir> <tag> <build-number>  > manifest.json

The manifest lists one installer per platform with its size and SHA-256.
CI signs the exact bytes with the Ed25519 update key (manifest.json.sig);
the server and every app verify that signature with the public key in
packaging/update-signing-public.pem before trusting any file.
"""
import datetime
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# platform key -> file name CI publishes (keys are what clients ask for)
ASSETS = {
    "windows": "PeanutButter-windows-x64-setup.exe",
    "macos": "PeanutButter-macos-universal.zip",
    "linux-appimage": "PeanutButter-linux-x86_64.AppImage",
    "linux-deb": "PeanutButter-linux-amd64.deb",
    "android-tv": "PeanutButter-android-tv.apk",
    # Per-CPU APKs: a fraction of the universal one's size for most TVs.
    "android-tv-arm64-v8a": "PeanutButter-android-tv-arm64-v8a.apk",
    "android-tv-armeabi-v7a": "PeanutButter-android-tv-armeabi-v7a.apk",
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    release_dir, tag, build = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    m = re.match(r"^v(\d+\.\d+\.\d+)(?:-([0-9A-Za-z.-]+))?$", tag)
    if not m:
        print(f"tag {tag!r} is not vX.Y.Z[-pre]", file=sys.stderr)
        return 2
    assets = {}
    for platform, name in ASSETS.items():
        path = release_dir / name
        if not path.is_file():
            print(f"missing release file: {path}", file=sys.stderr)
            return 1
        assets[platform] = {
            "name": name,
            "size": path.stat().st_size,
            "sha256": sha256(path),
        }
    repo = os.environ.get("GITHUB_REPOSITORY", "PeanutButterOrg/PeanutButter")
    manifest = {
        "schema": 1,
        "version": m.group(1),
        "prerelease": m.group(2) is not None,
        "build": build,
        "tag": tag,
        "published_at": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
        "notes_url": f"https://github.com/{repo}/releases/tag/{tag}",
        "assets": assets,
    }
    json.dump(manifest, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
