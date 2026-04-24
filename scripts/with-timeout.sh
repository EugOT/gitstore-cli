#!/usr/bin/env bash
# Cross-platform timeout wrapper for verification scripts.
set -euo pipefail

duration_to_seconds() {
  local value="$1"
  case "$value" in
    *h) echo $(( ${value%h} * 3600 )) ;;
    *m) echo $(( ${value%m} * 60 )) ;;
    *s) echo "${value%s}" ;;
    *) echo "$value" ;;
  esac
}

run_with_timeout() {
  local duration="$1"
  shift

  if command -v timeout &>/dev/null; then
    timeout "$duration" "$@"
    return $?
  fi
  if command -v gtimeout &>/dev/null; then
    gtimeout "$duration" "$@"
    return $?
  fi

  local seconds pid watchdog marker status
  seconds=$(duration_to_seconds "$duration")
  marker=$(mktemp)
  rm -f "$marker"

  "$@" &
  pid=$!

  (
    sleep "$seconds"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$marker"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) &
  watchdog=$!

  wait "$pid"
  status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  if [[ -f "$marker" ]]; then
    rm -f "$marker"
    return 124
  fi
  rm -f "$marker"
  return $status
}
