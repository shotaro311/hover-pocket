#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE_NAME="voice-e2e-session.plist"
E2E_BUNDLE_IDENTIFIER="local.codex.hover-pocket.voice-e2e"
E2E_EXPECTED_PROVIDER="codex_app_server"
SESSION_OPERATION_LOCK=""

usage() {
  cat <<'USAGE'
Usage:
  ./script/voice_e2e_macos.sh Build [--session-dir <fresh temp directory>]
  ./script/voice_e2e_macos.sh Run --session-dir <directory>
  ./script/voice_e2e_macos.sh Readback --session-dir <directory>
  ./script/voice_e2e_macos.sh ValidateIsolation --session-dir <directory>
  ./script/voice_e2e_macos.sh Validate --session-dir <directory>
  ./script/voice_e2e_macos.sh Stop --session-dir <directory>
  ./script/voice_e2e_macos.sh Cleanup --session-dir <directory>

Build and Run use the logged-in Codex app-server account and never read an API
key from arguments or environment. Voice still requires explicit opt-in in the
isolated app Settings UI. New physical evidence is bound to codex_app_server;
Realtime BYOK receipts cannot satisfy Validate.
USAGE
}

temporary_root() {
  (cd "${TMPDIR:-/tmp}" && pwd -P)
}

validate_direct_temp_directory() {
  local configured="$1"
  local prefix="$2"
  local require_empty="$3"
  local resolved
  local temp
  [[ -d "$configured" && ! -L "$configured" ]] || {
    echo "error: expected a non-symlink directory" >&2
    return 1
  }
  resolved="$(cd "$configured" && pwd -P)"
  temp="$(temporary_root)"
  [[ "$(dirname "$resolved")" == "$temp" ]] || {
    echo "error: directory must be a direct child of the system temp directory" >&2
    return 1
  }
  [[ "$(basename "$resolved")" == "$prefix"* ]] || {
    echo "error: directory prefix is invalid" >&2
    return 1
  }
  if [[ "$require_empty" == "true" ]]; then
    [[ -z "$(find "$resolved" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
      echo "error: directory must be fresh" >&2
      return 1
    }
  fi
  printf '%s' "$resolved"
}

validate_session_directory() {
  validate_direct_temp_directory "$1" "HoverPocketVoiceE2ESession-" "$2"
}

validate_build_directory() {
  validate_direct_temp_directory "$1" "HoverPocketVoiceE2EBuild-" "false"
}

validate_runtime_directory() {
  validate_direct_temp_directory "$1" "HoverPocketVoiceE2E-" "$2"
}

state_path() {
  printf '%s/%s' "$1" "$STATE_FILE_NAME"
}

state_value() {
  /usr/bin/plutil -extract "$2" raw "$(state_path "$1")"
}

performance_receipt_required() {
  local session_dir="$1"
  local state_file
  state_file="$(state_path "$session_dir")"
  [[ "$(/usr/bin/plutil -extract performanceReceiptRequired raw "$state_file" 2>/dev/null || true)" == "true" ]]
}

require_state() {
  local session_dir="$1"
  local state_file
  state_file="$(state_path "$session_dir")"
  [[ -f "$state_file" && ! -L "$state_file" ]] || {
    echo "error: E2E session state is missing" >&2
    return 1
  }
  local schema_version
  schema_version="$(state_value "$session_dir" schemaVersion)"
  [[ "$schema_version" == "1" || "$schema_version" == "2" ]] || {
    echo "error: E2E session schema is unsupported" >&2
    return 1
  }
  if [[ "$schema_version" == "2" ]]; then
    [[ "$(state_value "$session_dir" expectedProviderId)" == "$E2E_EXPECTED_PROVIDER" ]] || {
      echo "error: E2E session provider binding is invalid" >&2
      return 1
    }
  fi
}

require_provider_bound_session() {
  local session_dir="$1"
  [[ "$(state_value "$session_dir" schemaVersion)" == "2" ]] || {
    echo "error: physical validation requires a provider-bound session created by the current harness" >&2
    return 1
  }
}

release_session_operation_lock() {
  if [[ -n "$SESSION_OPERATION_LOCK" ]]; then
    /bin/rmdir "$SESSION_OPERATION_LOCK" 2>/dev/null || true
    SESSION_OPERATION_LOCK=""
  fi
}

acquire_session_operation_lock() {
  local session_dir="$1"
  local lock_path="$session_dir/.voice-e2e-operation-lock"
  /bin/mkdir "$lock_path" 2>/dev/null || {
    echo "error: another E2E session operation is already running" >&2
    return 1
  }
  SESSION_OPERATION_LOCK="$lock_path"
  trap release_session_operation_lock EXIT
}

validate_bundle() {
  local app_path="$1"
  local build_root="$2"
  local expected_app="$build_root/HoverPocketVoiceE2E.app"
  local signature_info
  [[ "$app_path" == "$expected_app" && -d "$app_path" && ! -L "$app_path" ]] || {
    echo "error: E2E app path is invalid" >&2
    return 1
  }
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == "$E2E_BUNDLE_IDENTIFIER" ]] || {
    echo "error: E2E bundle identifier is invalid" >&2
    return 1
  }
  [[ "$(/usr/bin/plutil -extract HoverPocketVoiceE2EBuild raw "$app_path/Contents/Info.plist")" == "true" ]] || {
    echo "error: E2E bundle marker is missing" >&2
    return 1
  }
  [[ "$(/usr/bin/plutil -extract HoverPocketKeychainServiceSuffix raw "$app_path/Contents/Info.plist")" == voice-e2e-* ]] || {
    echo "error: E2E credential suffix is invalid" >&2
    return 1
  }
  if /usr/bin/plutil -extract SUFeedURL raw "$app_path/Contents/Info.plist" >/dev/null 2>&1; then
    echo "error: E2E bundle contains an update feed" >&2
    return 1
  fi
  if /usr/bin/plutil -extract GIDClientID raw "$app_path/Contents/Info.plist" >/dev/null 2>&1; then
    echo "error: E2E bundle contains Google OAuth configuration" >&2
    return 1
  fi
  signature_info="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)" || {
    echo "error: E2E bundle signature cannot be inspected" >&2
    return 1
  }
  grep -qx 'Signature=adhoc' <<< "$signature_info" || {
    echo "error: E2E bundle must use an ad-hoc signature" >&2
    return 1
  }
  if grep -q '^Authority=' <<< "$signature_info"; then
    echo "error: E2E bundle must not use a certificate identity" >&2
    return 1
  fi
  grep -qx 'TeamIdentifier=not set' <<< "$signature_info" || {
    echo "error: E2E bundle must not carry a signing team" >&2
    return 1
  }
}

process_command() {
  /bin/ps -p "$1" -o command= 2>/dev/null || true
}

validate_owned_process() {
  local pid="$1"
  local executable="$2"
  local runtime_root="$3"
  local command
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
  /bin/kill -0 "$pid" 2>/dev/null || return 1
  command="$(process_command "$pid")"
  [[ "$command" == "$executable --voice-e2e --voice-e2e-root $runtime_root" ]] || return 1
}

find_exact_process() {
  local expected="$1"
  /bin/ps -axo pid=,command= | /usr/bin/awk -v expected="$expected" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if ($0 == expected) print pid
    }
  '
}

build_action() {
  local requested_session="$1"
  local session_dir
  local build_root
  local state_file
  local suffix
  local app_path

  if [[ -n "$requested_session" ]]; then
    session_dir="$(validate_session_directory "$requested_session" true)"
  else
    session_dir="$(mktemp -d "$(temporary_root)/HoverPocketVoiceE2ESession-XXXXXX")"
  fi
  build_root="$(mktemp -d "$(temporary_root)/HoverPocketVoiceE2EBuild-XXXXXX")"
  suffix="voice-e2e-$(basename "$session_dir" | tr '[:upper:]' '[:lower:]')"
  app_path="$(
    HOVERPOCKET_VOICE_E2E_BUILD=1 \
    HOVERPOCKET_VOICE_E2E_BUILD_ROOT="$build_root" \
    HOVERPOCKET_KEYCHAIN_SERVICE_SUFFIX="$suffix" \
    SPARKLE_FEED_URL= \
    SPARKLE_PUBLIC_ED_KEY= \
    GOOGLE_SIGN_IN_CLIENT_ID= \
    GOOGLE_SIGN_IN_REVERSED_CLIENT_ID= \
    GOOGLE_CLIENT_ID= \
    GOOGLE_CLIENT_SECRET= \
    CODESIGN_IDENTITY=- \
    CODESIGN_HARDENED_RUNTIME= \
    "$ROOT_DIR/script/build_and_run.sh" --build-only | tail -1
  )"
  validate_bundle "$app_path" "$build_root"

  state_file="$(state_path "$session_dir")"
  /usr/bin/plutil -create xml1 "$state_file"
  /usr/bin/plutil -insert schemaVersion -integer 2 "$state_file"
  /usr/bin/plutil -insert expectedProviderId -string "$E2E_EXPECTED_PROVIDER" "$state_file"
  /usr/bin/plutil -insert lifecycle -string built "$state_file"
  /usr/bin/plutil -insert appPath -string "$app_path" "$state_file"
  /usr/bin/plutil -insert buildRoot -string "$build_root" "$state_file"
  /usr/bin/plutil -insert runtimeRoot -string "" "$state_file"
  /usr/bin/plutil -insert processIdentifier -integer 0 "$state_file"
  /usr/bin/plutil -insert performanceReceiptRequired -bool true "$state_file"
  /bin/chmod 600 "$state_file"

  printf 'voice_e2e_build=ok\n'
  printf 'voice_e2e_session_dir=%s\n' "$session_dir"
  printf 'voice_e2e_app=%s\n' "$app_path"
  printf 'voice_e2e_expected_provider=%s\n' "$E2E_EXPECTED_PROVIDER"
}

run_action() {
  local session_dir="$1"
  local app_path
  local build_root
  local runtime_root
  local executable
  local expected_command
  local matching_pids
  local pid

  require_state "$session_dir"
  [[ "$(state_value "$session_dir" lifecycle)" == "built" ]] || {
    echo "error: E2E session is not ready to run" >&2
    return 1
  }
  app_path="$(state_value "$session_dir" appPath)"
  build_root="$(validate_build_directory "$(state_value "$session_dir" buildRoot)")"
  validate_bundle "$app_path" "$build_root"
  runtime_root="$(mktemp -d "$(temporary_root)/HoverPocketVoiceE2E-XXXXXX")"
  runtime_root="$(validate_runtime_directory "$runtime_root" true)"
  executable="$app_path/Contents/MacOS/HoverPocket"
  expected_command="$executable --voice-e2e --voice-e2e-root $runtime_root"

  /usr/bin/open -n "$app_path" --args \
    --voice-e2e \
    --voice-e2e-root "$runtime_root"
  /usr/bin/plutil -replace lifecycle -string starting "$(state_path "$session_dir")"
  /usr/bin/plutil -replace runtimeRoot -string "$runtime_root" "$(state_path "$session_dir")"
  /usr/bin/plutil -replace processIdentifier -integer 0 "$(state_path "$session_dir")"

  for _ in {1..80}; do
    matching_pids="$(find_exact_process "$expected_command")"
    if [[ -n "$matching_pids" && ! "$matching_pids" =~ ^[0-9]+$ ]]; then
      /usr/bin/plutil -replace lifecycle -string built "$(state_path "$session_dir")"
      echo "error: isolated app process ownership is ambiguous" >&2
      return 1
    fi
    if [[ "$matching_pids" =~ ^[0-9]+$ ]]; then
      pid="$matching_pids"
      /usr/bin/plutil -replace processIdentifier -integer "$pid" "$(state_path "$session_dir")"
    fi
    if [[ "${pid:-}" =~ ^[0-9]+$ ]] \
        && validate_owned_process "$pid" "$executable" "$runtime_root" \
        && [[ -d "$runtime_root/CapabilityBroker" ]]; then
      /usr/bin/plutil -replace lifecycle -string running "$(state_path "$session_dir")"
      printf 'voice_e2e_run=ok\n'
      printf 'voice_e2e_session_dir=%s\n' "$session_dir"
      printf 'voice_e2e_runtime_root=%s\n' "$runtime_root"
      printf 'voice_e2e_pid=%s\n' "$pid"
      return 0
    fi
    /bin/sleep 0.1
  done
  /usr/bin/plutil -replace lifecycle -string built "$(state_path "$session_dir")"
  echo "error: isolated app did not publish its isolated runtime state" >&2
  return 1
}

readback_action() {
  local session_dir="$1"
  local app_path
  local build_root
  local runtime_root
  local pid
  local executable
  local process_state="stopped"
  local receipt_state="pending"
  local performance_state="pending"

  require_state "$session_dir"
  app_path="$(state_value "$session_dir" appPath)"
  build_root="$(validate_build_directory "$(state_value "$session_dir" buildRoot)")"
  validate_bundle "$app_path" "$build_root"
  runtime_root="$(state_value "$session_dir" runtimeRoot)"
  pid="$(state_value "$session_dir" processIdentifier)"
  if [[ -n "$runtime_root" ]]; then
    runtime_root="$(validate_runtime_directory "$runtime_root" false)"
  fi
  executable="$app_path/Contents/MacOS/HoverPocket"
  if [[ -n "$runtime_root" ]] && validate_owned_process "$pid" "$executable" "$runtime_root"; then
    process_state="running"
  fi
  if [[ -n "$runtime_root" && -f "$runtime_root/voice-e2e-receipt.json" ]]; then
    receipt_state="present"
  fi
  if [[ -n "$runtime_root" && -f "$runtime_root/voice-e2e-performance.json" ]]; then
    performance_state="present"
  fi

  printf 'voice_e2e_bundle=ok\n'
  printf 'voice_e2e_lifecycle=%s\n' "$(state_value "$session_dir" lifecycle)"
  printf 'voice_e2e_process=%s\n' "$process_state"
  printf 'voice_e2e_runtime_root=%s\n' "$runtime_root"
  printf 'voice_e2e_receipt=%s\n' "$receipt_state"
  printf 'voice_e2e_performance_receipt=%s\n' "$performance_state"
  if [[ "$(state_value "$session_dir" schemaVersion)" == "2" ]]; then
    printf 'voice_e2e_provider_binding=explicit\n'
  else
    printf 'voice_e2e_provider_binding=legacy_nonphysical_only\n'
  fi
  if [[ "$receipt_state" == "present" ]]; then
    "$ROOT_DIR/script/verify_macos_voice_e2e_receipt.py" \
      --runtime-root "$runtime_root" \
      --stage summary
  fi
  if [[ -n "$runtime_root" ]]; then
    if performance_receipt_required "$session_dir"; then
      "$ROOT_DIR/script/verify_macos_voice_e2e_performance.py" \
        --runtime-root "$runtime_root" \
        --receipt-only \
        --require-receipt \
        --stage idle
    elif [[ "$performance_state" == "present" ]]; then
      "$ROOT_DIR/script/verify_macos_voice_e2e_performance.py" \
        --runtime-root "$runtime_root" \
        --receipt-only \
        --stage idle
    fi
  fi
}

validate_action() {
  local session_dir="$1"
  local receipt_stage="$2"
  local runtime_root
  local pid
  local app_path
  local executable
  local allowed='^(CapabilityBroker|PocketApps|StickyNotes|Timer|Clipboard|voice-e2e-receipt.json|voice-e2e-performance.json)$'
  local entry
  local entry_path
  local resolved_entry

  require_state "$session_dir"
  if [[ "$receipt_stage" == "physical" ]]; then
    require_provider_bound_session "$session_dir"
  fi
  [[ "$(state_value "$session_dir" lifecycle)" == "running" ]] || {
    echo "error: E2E session is not running" >&2
    return 1
  }
  runtime_root="$(validate_runtime_directory "$(state_value "$session_dir" runtimeRoot)" false)"
  pid="$(state_value "$session_dir" processIdentifier)"
  app_path="$(state_value "$session_dir" appPath)"
  executable="$app_path/Contents/MacOS/HoverPocket"
  validate_owned_process "$pid" "$executable" "$runtime_root" || {
    echo "error: E2E process ownership readback failed" >&2
    return 1
  }
  while IFS= read -r -d '' entry_path; do
    entry="$(basename "$entry_path")"
    [[ "$entry" =~ $allowed ]] || {
      echo "error: unexpected top-level E2E data entry" >&2
      return 1
    }
    [[ ! -L "$entry_path" ]] || {
      echo "error: top-level E2E data entries must not be symlinks" >&2
      return 1
    }
    if [[ "$entry" == "voice-e2e-receipt.json" || "$entry" == "voice-e2e-performance.json" ]]; then
      [[ -f "$entry_path" ]] || {
        echo "error: E2E receipt must be a regular file" >&2
        return 1
      }
      resolved_entry="$(cd "$(dirname "$entry_path")" && pwd -P)/$entry"
    else
      [[ -d "$entry_path" ]] || {
        echo "error: E2E storage entries must be directories" >&2
        return 1
      }
      resolved_entry="$(cd "$entry_path" && pwd -P)"
    fi
    [[ "$resolved_entry" == "$runtime_root/$entry" ]] || {
      echo "error: top-level E2E data escaped the isolated runtime root" >&2
      return 1
    }
  done < <(find "$runtime_root" -mindepth 1 -maxdepth 1 -print0)
  if [[ "$receipt_stage" == "physical" ]]; then
    "$ROOT_DIR/script/verify_macos_voice_e2e_receipt.py" \
      --runtime-root "$runtime_root" \
      --expected-provider "$E2E_EXPECTED_PROVIDER" \
      --stage "$receipt_stage"
  else
    "$ROOT_DIR/script/verify_macos_voice_e2e_receipt.py" \
      --runtime-root "$runtime_root" \
      --stage "$receipt_stage"
  fi
  if performance_receipt_required "$session_dir"; then
    local performance_stage="idle"
    [[ "$receipt_stage" == "physical" ]] && performance_stage="active"
    "$ROOT_DIR/script/verify_macos_voice_e2e_performance.py" \
      --runtime-root "$runtime_root" \
      --pid "$pid" \
      --duration 3 \
      --require-receipt \
      --stage "$performance_stage"
  fi
  printf 'voice_e2e_validate=ok\n'
  printf 'voice_e2e_storage_isolation=ok\n'
  printf 'voice_e2e_process_ownership=ok\n'
  printf 'voice_e2e_expected_provider=%s\n' "$E2E_EXPECTED_PROVIDER"
}

stop_action() {
  local session_dir="$1"
  local runtime_root
  local pid
  local app_path
  local executable

  require_state "$session_dir"
  runtime_root="$(validate_runtime_directory "$(state_value "$session_dir" runtimeRoot)" false)"
  pid="$(state_value "$session_dir" processIdentifier)"
  app_path="$(state_value "$session_dir" appPath)"
  executable="$app_path/Contents/MacOS/HoverPocket"
  if validate_owned_process "$pid" "$executable" "$runtime_root"; then
    /usr/bin/osascript -l JavaScript \
      -e 'ObjC.import("AppKit"); function run(argv) { const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0])); if (!app) return "absent"; return String(app.terminate); }' \
      "$pid" >/dev/null 2>&1 || true
    for _ in {1..80}; do
      /bin/kill -0 "$pid" 2>/dev/null || break
      /bin/sleep 0.1
    done
    if /bin/kill -0 "$pid" 2>/dev/null; then
      validate_owned_process "$pid" "$executable" "$runtime_root" || {
        echo "error: process identity changed before fallback stop" >&2
        return 1
      }
      /bin/kill -TERM "$pid"
      for _ in {1..40}; do
        /bin/kill -0 "$pid" 2>/dev/null || break
        /bin/sleep 0.1
      done
    fi
  fi
  /bin/kill -0 "$pid" 2>/dev/null && {
    echo "error: isolated process did not stop" >&2
    return 1
  }
  "$ROOT_DIR/script/verify_macos_voice_e2e_receipt.py" \
    --runtime-root "$runtime_root" \
    --stage stopped
  if performance_receipt_required "$session_dir"; then
    "$ROOT_DIR/script/verify_macos_voice_e2e_performance.py" \
      --runtime-root "$runtime_root" \
      --receipt-only \
      --require-receipt \
      --stage stopped
  fi
  /usr/bin/plutil -replace lifecycle -string stopped "$(state_path "$session_dir")"
  printf 'voice_e2e_stop=ok\n'
  printf 'voice_e2e_process=stopped\n'
}

cleanup_action() {
  local session_dir="$1"
  local lifecycle
  local build_root
  local runtime_root
  local pid
  local app_path
  local executable
  local expected_command
  local matching_pids

  require_state "$session_dir"
  lifecycle="$(state_value "$session_dir" lifecycle)"
  [[ "$lifecycle" == "built" || "$lifecycle" == "stopped" ]] || {
    echo "error: stop the E2E session before cleanup" >&2
    return 1
  }
  pid="$(state_value "$session_dir" processIdentifier)"
  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] && /bin/kill -0 "$pid" 2>/dev/null; then
    echo "error: E2E process is still running" >&2
    return 1
  fi
  build_root="$(validate_build_directory "$(state_value "$session_dir" buildRoot)")"
  app_path="$(state_value "$session_dir" appPath)"
  validate_bundle "$app_path" "$build_root"
  runtime_root="$(state_value "$session_dir" runtimeRoot)"
  if [[ -n "$runtime_root" ]]; then
    runtime_root="$(validate_runtime_directory "$runtime_root" false)"
    executable="$app_path/Contents/MacOS/HoverPocket"
    expected_command="$executable --voice-e2e --voice-e2e-root $runtime_root"
    matching_pids="$(find_exact_process "$expected_command")"
    [[ -z "$matching_pids" ]] || {
      echo "error: an exact E2E process is still running" >&2
      return 1
    }
    /usr/bin/trash "$runtime_root"
  fi
  /usr/bin/trash "$build_root"
  /usr/bin/trash "$session_dir"
  printf 'voice_e2e_cleanup=trashed\n'
}

action="${1:-}"
[[ -n "$action" ]] || { usage; exit 2; }
shift
session_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      session_dir="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

normalized_action="$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')"
case "$normalized_action" in
  build)
    build_action "$session_dir"
    ;;
  run|readback|validate|validateisolation|stop|cleanup)
    [[ -n "$session_dir" ]] || { usage; exit 2; }
    session_dir="$(validate_session_directory "$session_dir" false)"
    if [[ "$normalized_action" == "run" \
        || "$normalized_action" == "stop" \
        || "$normalized_action" == "cleanup" ]]; then
      acquire_session_operation_lock "$session_dir"
    fi
    case "$normalized_action" in
      validate)
        validate_action "$session_dir" physical
        ;;
      validateisolation)
        validate_action "$session_dir" isolation
        ;;
      *)
        "${normalized_action}_action" "$session_dir"
        ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac
