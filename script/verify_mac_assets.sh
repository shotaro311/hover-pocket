#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
python3 script/verify_voice_foundation.py
if [[ "${1:-}" != "--skip-build" ]]; then
  BUNDLE_IDENTIFIER=local.codex.hover-pocket.asset-dev HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX=asset-dev APP_BUILD=666 ./script/build_and_run.sh --build-only
fi
EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp/}HoverPocket-Assets-XXXXXX")"
APP="$ROOT_DIR/dist/HoverPocket.app/Contents/MacOS/HoverPocket"
for phase in library ui reopen; do
  "$APP" "--verify-asset-$phase" --asset-evidence "$EVIDENCE_DIR" --asset-source-root "$ROOT_DIR" > "$EVIDENCE_DIR/$phase.log" 2>&1 || { cat "$EVIDENCE_DIR/$phase.log"; exit 1; }
  tail -1 "$EVIDENCE_DIR/$phase.log"
done
for phase in chat library-voice personal-tools voice-only-confirmation capabilities broker panel-layout clipboard timer panel-soak; do
  "$APP" "--verify-$phase" --asset-evidence "$EVIDENCE_DIR" > "$EVIDENCE_DIR/$phase.log" 2>&1 || { cat "$EVIDENCE_DIR/$phase.log"; exit 1; }
  cat "$EVIDENCE_DIR/$phase.log"
done
git diff --check
codesign --verify --deep --strict "$ROOT_DIR/dist/HoverPocket.app"
echo "Evidence: $EVIDENCE_DIR"
