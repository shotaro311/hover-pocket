#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXECUTABLE_PATH="$ROOT_DIR/dist/NotchPokke.app/Contents/MacOS/NotchPokke"

"$ROOT_DIR/script/build_and_run.sh" --build-only >/dev/null
"$EXECUTABLE_PATH" --verify-google-calendar "$@"
