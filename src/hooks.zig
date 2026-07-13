/// Shell hook string literals and rclone filter rules.
/// Printed to stdout by "zt hook --zsh", "zt hook --bash", "zt hook --nu".
///
/// z3store design: `zt` now has native get/list/root/rm/create/migrate
/// subcommands. The ghq() shell function is a thin passthrough — no more
/// before/after `ghq list` diff dance. Adoption happens inside `zt get`.
pub const zsh_hook =
    \\# z3store-ghq-hook.zsh — transparent ghq→zt passthrough
    \\# Source this file in your .zshrc or place it in ~/.config/zsh/functions/
    \\#
    \\# Shadows the ghq command with a passthrough to `zt`. All ghq
    \\# subcommands (get, list, root, rm, create, migrate) map 1:1 to the same
    \\# subcommand on `zt`. Adoption into the z3store layout happens
    \\# inside `zt get` — no shell-side diff dance.
    \\#
    \\# If `zt` is absent from PATH, falls back to the real ghq binary.
    \\
    \\ghq() {
    \\  if whence -p zt >/dev/null 2>&1; then
    \\    command zt "$@"
    \\  elif whence -p ghq >/dev/null 2>&1; then
    \\    command ghq "$@"
    \\  else
    \\    echo "ghq(): neither zt nor ghq found on PATH" >&2
    \\    return 127
    \\  fi
    \\}
;

pub const bash_hook =
    \\# z3store-ghq-hook.bash — transparent ghq→zt passthrough
    \\# Source this file in your .bashrc or .bash_profile.
    \\#
    \\# Shadows the ghq command with a passthrough to `zt`. All ghq
    \\# subcommands map 1:1. Adoption happens inside `zt get` — no
    \\# shell-side diff dance.
    \\#
    \\# If `zt` is absent from PATH, falls back to the real ghq binary.
    \\
    \\ghq() {
    \\  if type -P zt >/dev/null 2>&1; then
    \\    command zt "$@"
    \\  elif type -P ghq >/dev/null 2>&1; then
    \\    command ghq "$@"
    \\  else
    \\    echo "ghq(): neither zt nor ghq found on PATH" >&2
    \\    return 127
    \\  fi
    \\}
;

pub const nu_hook =
    \\# z3store.nu — nushell module for z3store integration
    \\# Usage: use z3store.nu
    \\#
    \\# Transparent ghq→zt passthrough. `zt` has native
    \\# get/list/root/rm/create/migrate, so the wrapper forwards all args.
    \\# Falls back to real ghq binary if zt is not installed.
    \\
    \\export def --wrapped ghq [...args: string] {
    \\  if (which zt | where type == external | is-not-empty) {
    \\    ^zt ...$args
    \\  } else if (which ghq | where type == external | is-not-empty) {
    \\    ^ghq ...$args
    \\  } else {
    \\    error make {msg: "ghq(): neither zt nor ghq found on PATH"}
    \\  }
    \\}
    \\
    \\# Show z3store status as a structured table
    \\export def zt-status [] {
    \\  if (which zt | where type == external | is-empty) {
    \\    error make { msg: "zt-status: zt not found on PATH" }
    \\  }
    \\
    \\  let result = (do { ^zt status --json } | complete)
    \\
    \\  if $result.exit_code != 0 {
    \\    print -e $result.stderr
    \\    error make { msg: "zt status failed" }
    \\  }
    \\
    \\  $result.stdout | from json
    \\}
;

pub const gh_zsh_hook =
    \\# z3store-gh-hook.zsh — opt-in GitHub CLI compatibility for synced trees
    \\# Source this only when you want `gh` to derive GH_REPO from z3store/ghq paths
    \\# that no longer contain a .git file after rclone/Google Drive sync.
    \\#
    \\# Uses `command gh` so 1Password's `op plugin run -- gh` alias still works.
    \\
    \\gh() {
    \\  if [ -n "${GH_REPO:-}" ]; then
    \\    GH_REPO="$GH_REPO" command gh "$@"
    \\    return $?
    \\  fi
    \\  if whence -p zt >/dev/null 2>&1; then
    \\    local _zt_gh_repo
    \\    local _zt_gh_error
    \\    local _zt_gh_status=0
    \\    local _zt_gh_stdout_file
    \\    _zt_gh_stdout_file="$(mktemp "${TMPDIR:-/tmp}/zt-gh-repo.XXXXXX")" || {
    \\      printf '%s\n' "zt gh-repo temp file creation failed" >&2
    \\      return 1
    \\    }
    \\    _zt_gh_error="$(command zt gh-repo 2>&1 1>"$_zt_gh_stdout_file")" || _zt_gh_status=$?
    \\    local _zt_read_status=0
    \\    _zt_gh_repo="$(cat "$_zt_gh_stdout_file")" || _zt_read_status=$?
    \\    if [ "$_zt_read_status" -ne 0 ]; then
    \\      rm -f "$_zt_gh_stdout_file" || printf '%s\n' "zt gh-repo temp file cleanup failed" >&2
    \\      printf '%s\n' "zt gh-repo stdout read failed" >&2
    \\      return 1
    \\    fi
    \\    rm -f "$_zt_gh_stdout_file" || printf '%s\n' "zt gh-repo temp file cleanup failed" >&2
    \\    if [ "$_zt_gh_status" -eq 0 ] && [ -n "$_zt_gh_repo" ]; then
    \\      GH_REPO="$_zt_gh_repo" command gh "$@"
    \\      return $?
    \\    fi
    \\    if [ "$_zt_gh_status" -eq 0 ]; then
    \\      printf '%s\n' "zt gh-repo returned empty GH_REPO" >&2
    \\      return 1
    \\    fi
    \\    if [ "$_zt_gh_status" -eq 1 ]; then
    \\      case "$_zt_gh_error" in
    \\        *"cannot derive GH_REPO"*)
    \\          command gh "$@"
    \\          return $?
    \\          ;;
    \\      esac
    \\    fi
    \\    printf '%s\n' "$_zt_gh_error" >&2
    \\    return "$_zt_gh_status"
    \\  fi
    \\  command gh "$@"
    \\}
;

pub const gh_bash_hook =
    \\# z3store-gh-hook.bash — opt-in GitHub CLI compatibility for synced trees
    \\# Source this only when you want `gh` to derive GH_REPO from z3store/ghq paths
    \\# that no longer contain a .git file after rclone/Google Drive sync.
    \\#
    \\# Uses `command gh` so 1Password's `op plugin run -- gh` alias still works.
    \\
    \\gh() {
    \\  if [ -n "${GH_REPO:-}" ]; then
    \\    GH_REPO="$GH_REPO" command gh "$@"
    \\    return $?
    \\  fi
    \\  if type -P zt >/dev/null 2>&1; then
    \\    local _zt_gh_repo
    \\    local _zt_gh_error
    \\    local _zt_gh_status=0
    \\    local _zt_gh_stdout_file
    \\    _zt_gh_stdout_file="$(mktemp "${TMPDIR:-/tmp}/zt-gh-repo.XXXXXX")" || {
    \\      printf '%s\n' "zt gh-repo temp file creation failed" >&2
    \\      return 1
    \\    }
    \\    _zt_gh_error="$(command zt gh-repo 2>&1 1>"$_zt_gh_stdout_file")" || _zt_gh_status=$?
    \\    local _zt_read_status=0
    \\    _zt_gh_repo="$(cat "$_zt_gh_stdout_file")" || _zt_read_status=$?
    \\    if [ "$_zt_read_status" -ne 0 ]; then
    \\      rm -f "$_zt_gh_stdout_file" || printf '%s\n' "zt gh-repo temp file cleanup failed" >&2
    \\      printf '%s\n' "zt gh-repo stdout read failed" >&2
    \\      return 1
    \\    fi
    \\    rm -f "$_zt_gh_stdout_file" || printf '%s\n' "zt gh-repo temp file cleanup failed" >&2
    \\    if [ "$_zt_gh_status" -eq 0 ] && [ -n "$_zt_gh_repo" ]; then
    \\      GH_REPO="$_zt_gh_repo" command gh "$@"
    \\      return $?
    \\    fi
    \\    if [ "$_zt_gh_status" -eq 0 ]; then
    \\      printf '%s\n' "zt gh-repo returned empty GH_REPO" >&2
    \\      return 1
    \\    fi
    \\    if [ "$_zt_gh_status" -eq 1 ]; then
    \\      case "$_zt_gh_error" in
    \\        *"cannot derive GH_REPO"*)
    \\          command gh "$@"
    \\          return $?
    \\          ;;
    \\      esac
    \\    fi
    \\    printf '%s\n' "$_zt_gh_error" >&2
    \\    return "$_zt_gh_status"
    \\  fi
    \\  command gh "$@"
    \\}
;

pub const gh_nu_hook =
    \\# z3store-gh.nu — opt-in GitHub CLI compatibility for synced trees
    \\# Usage: use this module after confirming you want `gh` wrapped.
    \\#
    \\# Uses `^gh` (external) so 1Password's `op plugin run -- gh` alias still works.
    \\
    \\def --wrapped _zt_run_gh [...args: string] {
    \\  ^gh ...$args
    \\}
    \\
    \\export def --wrapped gh [...args: string] {
    \\  let explicit_gh_repo = ($env.GH_REPO? | default "")
    \\  if ($explicit_gh_repo | is-not-empty) {
    \\    _zt_run_gh ...$args
    \\    return
    \\  }
    \\  if (which zt | is-not-empty) {
    \\    let resolved = (do { ^zt gh-repo } | complete)
    \\    let resolved_gh_repo = ($resolved.stdout | str trim)
    \\    if $resolved.exit_code == 0 and ($resolved_gh_repo | is-not-empty) {
    \\      with-env { GH_REPO: $resolved_gh_repo } { _zt_run_gh ...$args }
    \\      return
    \\    }
    \\    if $resolved.exit_code == 0 {
    \\      error make { msg: "zt gh-repo returned empty GH_REPO" }
    \\    }
    \\    if $resolved.exit_code == 1 and ($resolved.stderr | str contains "cannot derive GH_REPO") {
    \\      _zt_run_gh ...$args
    \\      return
    \\    }
    \\    if $resolved.exit_code != 0 {
    \\      error make { msg: $resolved.stderr }
    \\    }
    \\  }
    \\  _zt_run_gh ...$args
    \\}
;

/// rclone filter rules for syncing zt/z3store working trees to Google Drive.
/// Excludes VCS internals, build artifacts, caches, env files, OS junk.
/// Used by "zt sync" and "zt filter".
pub const rclone_filter =
    \\# z3store rclone filter rules
    \\# Generated by: zt filter
    \\# Use with: rclone sync --filter-from <this-file>
    \\
    \\# === VCS internals (should already be separated, belt-and-suspenders) ===
    \\- .git
    \\- .git/**
    \\- .jj
    \\- .jj/**
    \\- .hg/**
    \\- .svn/**
    \\
    \\# === Language build artifacts & caches ===
    \\# Zig
    \\- .zig-cache/**
    \\- zig-cache/**
    \\- zig-out/**
    \\
    \\# Rust
    \\- target/**
    \\
    \\# Node / Bun / Deno
    \\- node_modules/**
    \\- .next/**
    \\- .nuxt/**
    \\- .output/**
    \\- dist/**
    \\- .turbo/**
    \\- .vercel/**
    \\- .svelte-kit/**
    \\
    \\# Python
    \\- __pycache__/**
    \\- *.pyc
    \\- .venv/**
    \\- .pixi/**
    \\- .conda/**
    \\- .ruff_cache/**
    \\- .mypy_cache/**
    \\- .pytest_cache/**
    \\- *.egg-info/**
    \\
    \\# R / renv
    \\- renv/library/**
    \\- renv/staging/**
    \\- .Rproj.user/**
    \\
    \\# Go
    \\- vendor/**
    \\
    \\# Java / Scala / JVM
    \\- .gradle/**
    \\- .sbt/**
    \\- .metals/**
    \\- .bloop/**
    \\- .bsp/**
    \\
    \\# Swift / Xcode
    \\- .build/**
    \\- DerivedData/**
    \\- xcuserdata/**
    \\- *.xcodeproj/xcuserdata/**
    \\
    \\# Elixir
    \\- _build/**
    \\- deps/**
    \\
    \\# Nix
    \\- result
    \\- result-*
    \\
    \\# === Editor / IDE state ===
    \\- .idea/**
    \\- .vscode/**
    \\- .cursor/**
    \\- .claude/**
    \\- .omc/**
    \\- .agent/**
    \\- .factory/**
    \\
    \\# === OS junk ===
    \\- .DS_Store
    \\- Thumbs.db
    \\- desktop.ini
    \\
    \\# === Secrets / env (never sync) ===
    \\- .env
    \\- .env.*
    \\- *.pem
    \\- *.key
    \\- credentials.json
    \\- service-account*.json
    \\
    \\# === Miscellaneous caches & logs ===
    \\- .cache/**
    \\- .parcel-cache/**
    \\- .eslintcache
    \\- *.log
    \\- *.swp
    \\- *.swo
    \\- *~
;

// =========================================================
// Tests — assert the new passthrough shape. Named "hook:"
// for easy filtering. These supersede the legacy diff-dance
// assertions (comm -13, before/after) which no longer apply.
// =========================================================

const testing = @import("std").testing;
const mem = @import("std").mem;

test "hook: zsh defines ghq() function" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "ghq() {") != null);
}

test "hook: zsh prefers zt over ghq" {
    const zt_cmd_index = mem.indexOf(u8, zsh_hook, "whence -p zt").?;
    const ghq = mem.indexOf(u8, zsh_hook, "whence -p ghq").?;
    try testing.expect(zt_cmd_index < ghq);
}

test "hook: zsh uses PATH-only executable probes" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "whence -p zt") != null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "whence -p ghq") != null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "command -v ghq") == null);
}

test "hook: zsh forwards all args to zt" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "command zt \"$@\"") != null);
}

test "hook: zsh falls back to ghq when zt missing" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "command ghq \"$@\"") != null);
}

test "hook: zsh exits 127 when neither tool present" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "return 127") != null);
}

test "hook: zsh has no legacy diff-dance" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "comm -13") == null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "before=") == null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "after=") == null);
}

test "hook: bash defines ghq() function" {
    try testing.expect(mem.indexOf(u8, bash_hook, "ghq() {") != null);
}

test "hook: bash prefers zt over ghq" {
    const zt_cmd_index = mem.indexOf(u8, bash_hook, "type -P zt").?;
    const ghq = mem.indexOf(u8, bash_hook, "type -P ghq").?;
    try testing.expect(zt_cmd_index < ghq);
}

test "hook: bash uses PATH-only executable probes" {
    try testing.expect(mem.indexOf(u8, bash_hook, "type -P zt") != null);
    try testing.expect(mem.indexOf(u8, bash_hook, "type -P ghq") != null);
    try testing.expect(mem.indexOf(u8, bash_hook, "command -v ghq") == null);
}

test "hook: bash forwards all args to zt" {
    try testing.expect(mem.indexOf(u8, bash_hook, "command zt \"$@\"") != null);
}

test "hook: bash falls back to ghq when zt missing" {
    try testing.expect(mem.indexOf(u8, bash_hook, "command ghq \"$@\"") != null);
}

test "hook: bash has no legacy diff-dance" {
    try testing.expect(mem.indexOf(u8, bash_hook, "comm -13") == null);
    try testing.expect(mem.indexOf(u8, bash_hook, "ghq list --full-path") == null);
}

test "hook: nu defines wrapped ghq" {
    try testing.expect(mem.indexOf(u8, nu_hook, "export def --wrapped ghq") != null);
}

test "hook: nu prefers zt" {
    try testing.expect(mem.indexOf(u8, nu_hook, "which zt | where type == external") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "^zt ...$args") != null);
}

test "hook: nu falls back to ghq" {
    try testing.expect(mem.indexOf(u8, nu_hook, "which ghq | where type == external") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "^ghq ...$args") != null);
}

test "hook: nu raises an error when both tools are missing" {
    try testing.expect(mem.indexOf(
        u8,
        nu_hook,
        "error make {msg: \"ghq(): neither zt nor ghq found on PATH\"}",
    ) != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "exit 127") == null);
}

test "hook: nu has no legacy diff-dance" {
    try testing.expect(mem.indexOf(u8, nu_hook, "comm -13") == null);
    try testing.expect(mem.indexOf(u8, nu_hook, "let before") == null);
    try testing.expect(mem.indexOf(u8, nu_hook, "let after") == null);
}

test "hook: nu retains zt-status helper for structured output" {
    try testing.expect(mem.indexOf(u8, nu_hook, "zt-status") != null);
    const probe = mem.indexOf(u8, nu_hook, "which zt | where type == external | is-empty").?;
    const status = mem.indexOf(u8, nu_hook, "zt status --json").?;
    try testing.expect(probe < status);
    try testing.expect(mem.indexOf(u8, nu_hook, "zt status --json") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "from json") != null);
}

test "hook: rclone_filter preserves VCS + build-artifact rules" {
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .git/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .jj/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .zig-cache/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- target/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .DS_Store") != null);
}
