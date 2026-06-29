/// Shell hook string literals and rclone filter rules.
/// Printed to stdout by "gitstore hook --zsh", "gitstore hook --bash", "gitstore hook --nu".
///
/// libgitstore v2 design: `gitstore` now has native get/list/root/rm/create/migrate
/// subcommands. The ghq() shell function is a thin passthrough — no more
/// before/after `ghq list` diff dance. Adoption happens inside `gitstore get`.
pub const zsh_hook =
    \\# gitstore-ghq-hook.zsh — transparent ghq→gitstore passthrough
    \\# Source this file in your .zshrc or place it in ~/.config/zsh/functions/
    \\#
    \\# Shadows the ghq command with a passthrough to `gitstore`. All ghq
    \\# subcommands (get, list, root, rm, create, migrate) map 1:1 to the same
    \\# subcommand on `gitstore`. Adoption into the gitstore layout happens
    \\# inside `gitstore get` — no shell-side diff dance.
    \\#
    \\# If `gitstore` is absent from PATH, falls back to the real ghq binary.
    \\
    \\ghq() {
    \\  if whence -p gitstore >/dev/null 2>&1; then
    \\    command gitstore "$@"
    \\  elif whence -p ghq >/dev/null 2>&1; then
    \\    command ghq "$@"
    \\  else
    \\    echo "ghq(): neither gitstore nor ghq found on PATH" >&2
    \\    return 127
    \\  fi
    \\}
;

pub const bash_hook =
    \\# gitstore-ghq-hook.bash — transparent ghq→gitstore passthrough
    \\# Source this file in your .bashrc or .bash_profile.
    \\#
    \\# Shadows the ghq command with a passthrough to `gitstore`. All ghq
    \\# subcommands map 1:1. Adoption happens inside `gitstore get` — no
    \\# shell-side diff dance.
    \\#
    \\# If `gitstore` is absent from PATH, falls back to the real ghq binary.
    \\
    \\ghq() {
    \\  if type -P gitstore >/dev/null 2>&1; then
    \\    command gitstore "$@"
    \\  elif type -P ghq >/dev/null 2>&1; then
    \\    command ghq "$@"
    \\  else
    \\    echo "ghq(): neither gitstore nor ghq found on PATH" >&2
    \\    return 127
    \\  fi
    \\}
;

pub const nu_hook =
    \\# gitstore.nu — nushell module for gitstore integration
    \\# Usage: use gitstore.nu
    \\#
    \\# Transparent ghq→gitstore passthrough. `gitstore` has native
    \\# get/list/root/rm/create/migrate, so the wrapper forwards all args.
    \\# Falls back to real ghq binary if gitstore is not installed.
    \\
    \\export def --wrapped ghq [...args: string] {
    \\  if (which gitstore | is-not-empty) {
    \\    ^gitstore ...$args
    \\  } else if (which ghq | is-not-empty) {
    \\    ^ghq ...$args
    \\  } else {
    \\    print -e "ghq(): neither gitstore nor ghq found on PATH"
    \\    exit 127
    \\  }
    \\}
    \\
    \\# Show gitstore status as a structured table
    \\export def gitstore-status [] {
    \\  let result = (do { ^gitstore status --json } | complete)
    \\
    \\  if $result.exit_code != 0 {
    \\    print -e $result.stderr
    \\    error make { msg: "gitstore status failed" }
    \\  }
    \\
    \\  $result.stdout | from json
    \\}
;

pub const gh_zsh_hook =
    \\# gitstore-gh-hook.zsh — opt-in GitHub CLI compatibility for synced trees
    \\# Source this only when you want `gh` to derive GH_REPO from gitstore/ghq paths
    \\# that no longer contain a .git file after rclone/Google Drive sync.
    \\
    \\gh() {
    \\  if [ -n "${GH_REPO:-}" ]; then
    \\    GH_REPO="$GH_REPO" command gh "$@"
    \\    return $?
    \\  fi
    \\  if whence -p gitstore >/dev/null 2>&1; then
    \\    local _gitstore_gh_repo
    \\    local _gitstore_gh_error
    \\    local _gitstore_gh_status=0
    \\    local _gitstore_gh_stdout_file
    \\    _gitstore_gh_stdout_file="$(mktemp "${TMPDIR:-/tmp}/gitstore-gh-repo.XXXXXX")" || {
    \\      printf '%s\n' "gitstore gh-repo temp file creation failed" >&2
    \\      return 1
    \\    }
    \\    _gitstore_gh_error="$(command gitstore gh-repo 2>&1 1>"$_gitstore_gh_stdout_file")" || _gitstore_gh_status=$?
    \\    local _gitstore_read_status=0
    \\    _gitstore_gh_repo="$(cat "$_gitstore_gh_stdout_file")" || _gitstore_read_status=$?
    \\    if [ "$_gitstore_read_status" -ne 0 ]; then
    \\      rm -f "$_gitstore_gh_stdout_file" || printf '%s\n' "gitstore gh-repo temp file cleanup failed" >&2
    \\      printf '%s\n' "gitstore gh-repo stdout read failed" >&2
    \\      return 1
    \\    fi
    \\    rm -f "$_gitstore_gh_stdout_file" || printf '%s\n' "gitstore gh-repo temp file cleanup failed" >&2
    \\    if [ "$_gitstore_gh_status" -eq 0 ] && [ -n "$_gitstore_gh_repo" ]; then
    \\      GH_REPO="$_gitstore_gh_repo" command gh "$@"
    \\      return $?
    \\    fi
    \\    if [ "$_gitstore_gh_status" -eq 0 ]; then
    \\      printf '%s\n' "gitstore gh-repo returned empty GH_REPO" >&2
    \\      return 1
    \\    fi
    \\    if [ "$_gitstore_gh_status" -eq 1 ]; then
    \\      case "$_gitstore_gh_error" in
    \\        *"cannot derive GH_REPO"*)
    \\          command gh "$@"
    \\          return $?
    \\          ;;
    \\      esac
    \\    fi
    \\    printf '%s\n' "$_gitstore_gh_error" >&2
    \\    return "$_gitstore_gh_status"
    \\  fi
    \\  command gh "$@"
    \\}
;

pub const gh_bash_hook =
    \\# gitstore-gh-hook.bash — opt-in GitHub CLI compatibility for synced trees
    \\# Source this only when you want `gh` to derive GH_REPO from gitstore/ghq paths
    \\# that no longer contain a .git file after rclone/Google Drive sync.
    \\
    \\gh() {
    \\  if [ -n "${GH_REPO:-}" ]; then
    \\    GH_REPO="$GH_REPO" command gh "$@"
    \\    return $?
    \\  fi
    \\  if type -P gitstore >/dev/null 2>&1; then
    \\    local _gitstore_gh_repo
    \\    local _gitstore_gh_error
    \\    local _gitstore_gh_status=0
    \\    local _gitstore_gh_stdout_file
    \\    _gitstore_gh_stdout_file="$(mktemp "${TMPDIR:-/tmp}/gitstore-gh-repo.XXXXXX")" || {
    \\      printf '%s\n' "gitstore gh-repo temp file creation failed" >&2
    \\      return 1
    \\    }
    \\    _gitstore_gh_error="$(command gitstore gh-repo 2>&1 1>"$_gitstore_gh_stdout_file")" || _gitstore_gh_status=$?
    \\    local _gitstore_read_status=0
    \\    _gitstore_gh_repo="$(cat "$_gitstore_gh_stdout_file")" || _gitstore_read_status=$?
    \\    if [ "$_gitstore_read_status" -ne 0 ]; then
    \\      rm -f "$_gitstore_gh_stdout_file" || printf '%s\n' "gitstore gh-repo temp file cleanup failed" >&2
    \\      printf '%s\n' "gitstore gh-repo stdout read failed" >&2
    \\      return 1
    \\    fi
    \\    rm -f "$_gitstore_gh_stdout_file" || printf '%s\n' "gitstore gh-repo temp file cleanup failed" >&2
    \\    if [ "$_gitstore_gh_status" -eq 0 ] && [ -n "$_gitstore_gh_repo" ]; then
    \\      GH_REPO="$_gitstore_gh_repo" command gh "$@"
    \\      return $?
    \\    fi
    \\    if [ "$_gitstore_gh_status" -eq 0 ]; then
    \\      printf '%s\n' "gitstore gh-repo returned empty GH_REPO" >&2
    \\      return 1
    \\    fi
    \\    if [ "$_gitstore_gh_status" -eq 1 ]; then
    \\      case "$_gitstore_gh_error" in
    \\        *"cannot derive GH_REPO"*)
    \\          command gh "$@"
    \\          return $?
    \\          ;;
    \\      esac
    \\    fi
    \\    printf '%s\n' "$_gitstore_gh_error" >&2
    \\    return "$_gitstore_gh_status"
    \\  fi
    \\  command gh "$@"
    \\}
;

pub const gh_nu_hook =
    \\# gitstore-gh.nu — opt-in GitHub CLI compatibility for synced trees
    \\# Usage: use this module after confirming you want `gh` wrapped.
    \\
    \\def --wrapped _gitstore_run_gh [...args: string] {
    \\  ^gh ...$args
    \\}
    \\
    \\export def --wrapped gh [...args: string] {
    \\  let explicit_gh_repo = ($env.GH_REPO? | default "")
    \\  if ($explicit_gh_repo | is-not-empty) {
    \\    _gitstore_run_gh ...$args
    \\    return
    \\  }
    \\  if (which gitstore | is-not-empty) {
    \\    let resolved = (do { ^gitstore gh-repo } | complete)
    \\    let resolved_gh_repo = ($resolved.stdout | str trim)
    \\    if $resolved.exit_code == 0 and ($resolved_gh_repo | is-not-empty) {
    \\      with-env { GH_REPO: $resolved_gh_repo } { _gitstore_run_gh ...$args }
    \\      return
    \\    }
    \\    if $resolved.exit_code == 0 {
    \\      error make { msg: "gitstore gh-repo returned empty GH_REPO" }
    \\    }
    \\    if $resolved.exit_code == 1 and ($resolved.stderr | str contains "cannot derive GH_REPO") {
    \\      _gitstore_run_gh ...$args
    \\      return
    \\    }
    \\    if $resolved.exit_code != 0 {
    \\      error make { msg: $resolved.stderr }
    \\    }
    \\  }
    \\  _gitstore_run_gh ...$args
    \\}
;

/// rclone filter rules for syncing ghq working trees to Google Drive.
/// Excludes VCS internals, build artifacts, caches, env files, OS junk.
/// Used by "gitstore sync" and "gitstore filter".
pub const rclone_filter =
    \\# gitstore rclone filter rules
    \\# Generated by: gitstore filter
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

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;
const test_support = @import("test_support.zig");

fn writeHookFixture(
    io: Io,
    gpa: Allocator,
    namespace: []const u8,
    suffix: []const u8,
    hook: []const u8,
) ![]u8 {
    const path = try test_support.uniqueTempFile(gpa, io, namespace, suffix);
    errdefer gpa.free(path);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = hook });
    return path;
}

fn expectShellSyntax(io: Io, gpa: Allocator, argv: []const []const u8) !void {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try testing.expect(result.term == .exited);
    try testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "hook: gh zsh wrapper parses with zsh when available" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try writeHookFixture(io, gpa, "gh_zsh_hook", ".zsh", gh_zsh_hook);
    defer gpa.free(path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("hooks", err);
    try expectShellSyntax(io, gpa, &.{ "zsh", "-n", path });
}

test "hook: gh bash wrapper parses with bash when available" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try writeHookFixture(io, gpa, "gh_bash_hook", ".bash", gh_bash_hook);
    defer gpa.free(path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("hooks", err);
    try expectShellSyntax(io, gpa, &.{ "bash", "-n", path });
}

test "hook: gh nushell wrapper parses with nu when available" {
    const gpa = testing.allocator;
    const io = testing.io;
    const path = try writeHookFixture(io, gpa, "gh_nu_hook", ".nu", gh_nu_hook);
    defer gpa.free(path);
    defer Dir.cwd().deleteFile(io, path) catch |err| test_support.ignoreCleanupError("hooks", err);
    const driver = try std.fmt.allocPrint(gpa, "use '{s}' *\n", .{path});
    defer gpa.free(driver);
    const driver_path = try writeHookFixture(io, gpa, "gh_nu_hook_driver", ".nu", driver);
    defer gpa.free(driver_path);
    defer Dir.cwd().deleteFile(io, driver_path) catch |err| test_support.ignoreCleanupError("hooks", err);
    try expectShellSyntax(io, gpa, &.{ "nu", "--no-config-file", driver_path });
}

test "hook: zsh defines ghq() function" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "ghq() {") != null);
}

test "hook: zsh prefers gitstore over ghq" {
    const gs = mem.indexOf(u8, zsh_hook, "whence -p gitstore").?;
    const ghq = mem.indexOf(u8, zsh_hook, "whence -p ghq").?;
    try testing.expect(gs < ghq);
}

test "hook: zsh forwards all args to gitstore" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "command gitstore \"$@\"") != null);
}

test "hook: zsh falls back to ghq when gitstore missing" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "command ghq \"$@\"") != null);
}

test "hook: zsh exits 127 when neither tool present" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "return 127") != null);
}

test "hook: gh wrappers export GH_REPO only through gitstore gh-repo" {
    inline for (.{ gh_zsh_hook, gh_bash_hook }) |hook| {
        try testing.expect(mem.indexOf(u8, hook, "command gitstore gh-repo") != null);
        try testing.expect(mem.indexOf(u8, hook, "GH_REPO=\"$_gitstore_gh_repo\" command gh \"$@\"") != null);
    }
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "^gitstore gh-repo") != null);
    try testing.expect(mem.indexOf(
        u8,
        gh_nu_hook,
        "with-env { GH_REPO: $resolved_gh_repo } { _gitstore_run_gh ...$args }",
    ) != null);
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "def --wrapped _gitstore_run_gh") != null);
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "do { ^gh ...$args } | complete") == null);
    try testing.expectEqual(@as(usize, 4), mem.count(u8, gh_nu_hook, "_gitstore_run_gh ...$args"));
}

test "hook: gh wrappers ask gitstore before direct gh fallback" {
    inline for (.{ gh_zsh_hook, gh_bash_hook }) |hook| {
        try testing.expect(mem.indexOf(u8, hook, "git rev-parse --is-inside-work-tree") == null);
        const derive = mem.indexOf(u8, hook, "command gitstore gh-repo").?;
        const fallback = mem.lastIndexOf(u8, hook, "command gh \"$@\"").?;
        try testing.expect(derive < fallback);
    }
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "git rev-parse --is-inside-work-tree") == null);
    const derive = mem.indexOf(u8, gh_nu_hook, "^gitstore gh-repo").?;
    const fallback = mem.lastIndexOf(u8, gh_nu_hook, "_gitstore_run_gh ...$args").?;
    try testing.expect(derive < fallback);
}

test "hook: gh wrappers honor explicit GH_REPO override" {
    inline for (.{ gh_zsh_hook, gh_bash_hook }) |hook| {
        const override = mem.indexOf(u8, hook, "[ -n \"${GH_REPO:-}\" ]").?;
        const derive = mem.indexOf(u8, hook, "command gitstore gh-repo").?;
        try testing.expect(mem.indexOf(u8, hook, "GH_REPO=\"$GH_REPO\" command gh \"$@\"") != null);
        try testing.expect(override < derive);
    }
    const override = mem.indexOf(u8, gh_nu_hook, "$env.GH_REPO?").?;
    const derive = mem.indexOf(u8, gh_nu_hook, "^gitstore gh-repo").?;
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "$env.GH_REPO? | default \"\" | str trim") == null);
    try testing.expect(override < derive);
}

test "hook: gh wrappers surface unexpected gitstore gh-repo failures" {
    inline for (.{ gh_zsh_hook, gh_bash_hook }) |hook| {
        try testing.expect(mem.indexOf(
            u8,
            hook,
            "command gitstore gh-repo 2>&1 1>\"$_gitstore_gh_stdout_file\"",
        ) != null);
        try testing.expect(mem.indexOf(u8, hook, "|| _gitstore_gh_status=$?") != null);
        try testing.expect(mem.indexOf(u8, hook, "_gitstore_gh_error") != null);
        try testing.expect(mem.indexOf(u8, hook, "cannot derive GH_REPO") != null);
        try testing.expect(mem.indexOf(u8, hook, "gitstore gh-repo returned empty GH_REPO") != null);
        try testing.expect(mem.indexOf(u8, hook, "gitstore gh-repo temp file creation failed") != null);
        try testing.expect(mem.indexOf(u8, hook, "gitstore gh-repo stdout read failed") != null);
        try testing.expect(mem.indexOf(u8, hook, "gitstore gh-repo temp file cleanup failed") != null);
        try testing.expect(mem.indexOf(u8, hook,
            \\    _gitstore_gh_stdout_file="$(mktemp "${TMPDIR:-/tmp}/gitstore-gh-repo.XXXXXX")" || {
            \\      printf '%s\n' "gitstore gh-repo temp file creation failed" >&2
            \\      return 1
        ) != null);
        try testing.expect(mem.indexOf(u8, hook,
            \\    if [ "$_gitstore_read_status" -ne 0 ]; then
            \\      rm -f "$_gitstore_gh_stdout_file" || printf '%s\n' "gitstore gh-repo temp file cleanup failed" >&2
            \\      printf '%s\n' "gitstore gh-repo stdout read failed" >&2
            \\      return 1
        ) != null);
        try testing.expect(mem.indexOf(u8, hook, "return \"$_gitstore_mktemp_status\"") == null);
        try testing.expect(mem.indexOf(u8, hook, "return \"$_gitstore_read_status\"") == null);
        try testing.expect(mem.indexOf(u8, hook, "return \"$_gitstore_rm_status\"") == null);
        try testing.expect(mem.indexOf(u8, hook, ">&2") != null);
        try testing.expect(mem.indexOf(u8, hook, "return \"$_gitstore_gh_status\"") != null);
    }
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "cannot derive GH_REPO") != null);
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "resolved_gh_repo") != null);
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "gitstore gh-repo returned empty GH_REPO") != null);
    try testing.expect(mem.indexOf(u8, gh_nu_hook, "error make { msg: $resolved.stderr }") != null);
}

test "hook: zsh has no legacy diff-dance" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "comm -13") == null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "before=") == null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "after=") == null);
}

test "hook: bash defines ghq() function" {
    try testing.expect(mem.indexOf(u8, bash_hook, "ghq() {") != null);
}

test "hook: bash forwards all args to gitstore" {
    try testing.expect(mem.indexOf(u8, bash_hook, "command gitstore \"$@\"") != null);
}

test "hook: bash falls back to ghq when gitstore missing" {
    try testing.expect(mem.indexOf(u8, bash_hook, "command ghq \"$@\"") != null);
}

test "hook: bash has no legacy diff-dance" {
    try testing.expect(mem.indexOf(u8, bash_hook, "comm -13") == null);
    try testing.expect(mem.indexOf(u8, bash_hook, "ghq list --full-path") == null);
}

test "hook: nu defines wrapped ghq" {
    try testing.expect(mem.indexOf(u8, nu_hook, "export def --wrapped ghq") != null);
}

test "hook: nu prefers gitstore" {
    try testing.expect(mem.indexOf(u8, nu_hook, "which gitstore") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "^gitstore ...$args") != null);
}

test "hook: nu falls back to ghq" {
    try testing.expect(mem.indexOf(u8, nu_hook, "which ghq") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "^ghq ...$args") != null);
}

test "hook: nu exits 127 when neither tool present" {
    try testing.expect(mem.indexOf(u8, nu_hook, "exit 127") != null);
}

test "hook: nu has no legacy diff-dance" {
    try testing.expect(mem.indexOf(u8, nu_hook, "comm -13") == null);
    try testing.expect(mem.indexOf(u8, nu_hook, "let before") == null);
    try testing.expect(mem.indexOf(u8, nu_hook, "let after") == null);
}

test "hook: nu retains gitstore-status helper for structured output" {
    try testing.expect(mem.indexOf(u8, nu_hook, "gitstore-status") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "gitstore status --json") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "from json") != null);
}

test "hook: rclone_filter preserves VCS + build-artifact rules" {
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .git/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .jj/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .zig-cache/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- target/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .DS_Store") != null);
}
