#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_DIR="${BACKEND_DIR:-/home/ali/Desktop/PeanutButter-Backend-upload}"

echo "==> Pushing PeanutButterOrg/PeanutButter"
cd "$ROOT"
git push -u origin main

echo "==> Pushing PeanutButterOrg/PeanutButter-Backend"
cd "$BACKEND_DIR"
git push -u origin main

echo "Done."
echo "  https://github.com/PeanutButterOrg/PeanutButter"
echo "  https://github.com/PeanutButterOrg/PeanutButter-Backend"
