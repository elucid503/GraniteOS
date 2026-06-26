#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/frontend/public/qemu"
BASE="https://raw.githubusercontent.com/ktock/qemu-wasm-demo-images/main/raspi3ap"

mkdir -p "$DEST"

fetch() {

  local name="$1"
  local path="$DEST/$name"

  if [[ -f "$path" ]]; then

    echo "skip $name (exists)"
    return

  fi

  echo "fetch $name ..."
  curl -fsSL "$BASE/$name" -o "$path"

}

fetch out.js
fetch qemu-system-aarch64.wasm
fetch qemu-system-aarch64.worker.js

echo "QEMU Wasm assets ready in $DEST"
