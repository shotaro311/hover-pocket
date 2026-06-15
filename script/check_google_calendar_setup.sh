#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

read_env_key() {
  local key="$1"
  local file
  for file in "$ROOT_DIR/.env.local" "$ROOT_DIR/.env"; do
    if [[ -f "$file" ]]; then
      local value
      value="$(awk -F= -v key="$key" '
        $0 !~ /^[[:space:]]*#/ && $1 == key {
          sub(/^[^=]*=/, "")
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          gsub(/^"|"$/, "")
          gsub(/^'\''|'\''$/, "")
          print
          exit
        }
      ' "$file")"
      if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return
      fi
    fi
  done
}

status=0

native_client_id="${GOOGLE_SIGN_IN_CLIENT_ID:-$(read_env_key GOOGLE_SIGN_IN_CLIENT_ID)}"
legacy_client_id="${GOOGLE_CLIENT_ID:-$(read_env_key GOOGLE_CLIENT_ID)}"
if [[ -n "$native_client_id" ]]; then
  echo "google_ios_oauth_client_id=set"
elif [[ -n "$legacy_client_id" ]]; then
  echo "google_desktop_oauth_client_id=set"
else
  echo "google_oauth_client_id=missing"
  echo "next=run ./script/open_google_oauth_console.sh and create an iOS OAuth client"
  status=1
fi

if git check-ignore -q .env.local; then
  echo "env_local_gitignore=ok"
else
  echo "env_local_gitignore=missing"
  status=1
fi

if command -v gcloud >/dev/null 2>&1; then
  echo "gcloud=available"
  active_accounts="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$active_accounts" -gt 0 ]]; then
    echo "gcloud_active_account=set"
  else
    echo "gcloud_active_account=missing"
    status=1
  fi

  project="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -n "$project" && "$project" != "(unset)" ]]; then
    echo "gcloud_project=set"
    if gcloud services list --enabled --filter='config.name:calendar-json.googleapis.com OR config.name:calendar.googleapis.com' --format='value(config.name)' 2>/dev/null | rg -q 'calendar'; then
      echo "calendar_api=enabled"
    else
      echo "calendar_api=not_enabled_or_unknown"
      status=1
    fi
  else
    echo "gcloud_project=missing"
    status=1
  fi
else
  echo "gcloud=missing"
fi

exit "$status"
