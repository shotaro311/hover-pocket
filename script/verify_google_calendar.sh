#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXECUTABLE_PATH="$ROOT_DIR/dist/HoverPocket.app/Contents/MacOS/HoverPocket"

"$ROOT_DIR/script/build_and_run.sh" --build-only >/dev/null
"$EXECUTABLE_PATH" --verify-google-calendar "$@"
