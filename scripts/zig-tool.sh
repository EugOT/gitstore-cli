#!/usr/bin/env bash
# Shared Zig launcher for verification scripts. Prefer the repo-pinned
# stable Zig through mise, but allow callers to override with ZIG=/path/to/zig.

zig_cmd() {
  if [[ -n "${ZIG:-}" ]]; then
    "$ZIG" "$@"
  elif command -v mise &>/dev/null; then
    local root="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local trusted="${MISE_TRUSTED_CONFIG_PATHS:+$MISE_TRUSTED_CONFIG_PATHS:}$root"
    MISE_TRUSTED_CONFIG_PATHS="$trusted" mise x zig@0.16.0 -- zig "$@"
  else
    zig "$@"
  fi
}

zig_version() {
  zig_cmd version
}

zig_supports_fuzz() {
  local host_os version
  host_os="$(uname -s 2>/dev/null || echo unknown)"
  version="$(zig_version 2>/dev/null || true)"
  if [[ "${ZIG_QM_FORCE_FUZZ:-0}" != "1" && "$host_os" == "Darwin" && "$version" == "0.16.0" ]]; then
    return 1
  fi
  return 0
}

zig_fuzz_skip_message() {
  local host_os version
  host_os="$(uname -s 2>/dev/null || echo unknown)"
  version="$(zig_version 2>/dev/null || echo unknown)"
  printf '%s\n' "(native zig --fuzz skipped on $host_os with Zig $version; upstream macOS fuzz support is still incomplete in ziglang/zig#20986. Set ZIG_QM_FORCE_FUZZ=1 to try anyway.)"
}
