#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
DEST="$ROOT/frontend/public/assets"
KERNEL="$REPO_ROOT/zig-out/bin/kernel"
DISK="$REPO_ROOT/disk.img"

if [[ ! -f "$KERNEL" ]]; then

  echo "error: kernel not found at $KERNEL - run 'zig build' first" >&2
  exit 1

fi

if [[ ! -f "$DISK" ]]; then

  echo "error: disk.img not found at $DISK" >&2
  exit 1

fi

mkdir -p "$DEST"

cp -f "$KERNEL" "$DEST/kernel"
cp -f "$DISK"   "$DEST/disk.img"

echo "Assets copied to $DEST"
