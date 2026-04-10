/// Shell hook string literals and rclone filter rules.
/// Printed to stdout by "gitstore hook --zsh", "gitstore hook --nu", etc.

pub const zsh_hook =
    \\# gitstore-ghq-hook.zsh — transparent ghq wrapper with auto-adopt
    \\# Source this file in your .zshrc or place it in ~/.config/zsh/functions/
    \\#
    \\# Shadows the ghq command. All subcommands pass through unchanged.
    \\# After "ghq get" (with any flags like -P, -u, --shallow, etc.),
    \\# newly cloned repos are automatically adopted into gitstore.
    \\
    \\ghq() {
    \\  # Pass through if gitstore not available
    \\  if ! command -v gitstore &>/dev/null; then
    \\    command ghq "$@"
    \\    return $?
    \\  fi
    \\
    \\  # For non-get subcommands, just pass through
    \\  if [[ "$1" != "get" ]]; then
    \\    command ghq "$@"
    \\    return $?
    \\  fi
    \\
    \\  # Snapshot repos before clone to detect what's new
    \\  local before
    \\  before="$(command ghq list --full-path)"
    \\
    \\  # Run ghq get with all original flags (-P, -u, --shallow, etc.)
    \\  command ghq "$@"
    \\  local exit_code=$?
    \\
    \\  if [[ $exit_code -ne 0 ]]; then
    \\    return $exit_code
    \\  fi
    \\
    \\  # Diff repo list to find newly cloned repos
    \\  local after
    \\  after="$(command ghq list --full-path)"
    \\
    \\  local new_repos
    \\  new_repos="$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort))"
    \\
    \\  # Adopt any new repos
    \\  if [[ -n "$new_repos" ]]; then
    \\    while IFS= read -r repo_path; do
    \\      if [[ -d "$repo_path/.git" ]]; then
    \\        echo "gitstore: adopting $repo_path" >&2
    \\        command gitstore adopt "$repo_path"
    \\      fi
    \\    done <<< "$new_repos"
    \\  fi
    \\
    \\  # Also adopt updated repos (ghq get -u) that aren't yet adopted
    \\  # -u updates existing repos; their .git may still be a directory
    \\  if [[ "$*" == *"-u"* ]]; then
    \\    local repo_arg="${@: -1}"
    \\    local repo_path
    \\    repo_path="$(command ghq list --full-path | grep -F "$repo_arg" | tail -1)"
    \\    if [[ -n "$repo_path" && -d "$repo_path/.git" ]]; then
    \\      echo "gitstore: adopting $repo_path" >&2
    \\      command gitstore adopt "$repo_path"
    \\    fi
    \\  fi
    \\
    \\  return $exit_code
    \\}
;

pub const nu_hook =
    \\# gitstore.nu — nushell module for gitstore integration
    \\# Usage: use gitstore.nu
    \\#
    \\# Provides a transparent ghq wrapper. All subcommands pass through.
    \\# After "ghq get" (with any flags), new repos are auto-adopted.
    \\
    \\# Transparent ghq wrapper with auto-adopt on get
    \\export def --wrapped ghq [...args: string] {
    \\  # Non-get subcommands: pass through
    \\  if ($args | length) == 0 or ($args | first) != "get" {
    \\    ^ghq ...$args
    \\    return
    \\  }
    \\
    \\  # Snapshot repos before clone
    \\  let before = (^ghq list --full-path | lines)
    \\
    \\  # Run ghq get with all flags (-P, -u, --shallow, etc.)
    \\  let result = (do { ^ghq ...$args } | complete)
    \\
    \\  if ($result.stdout | str length) > 0 {
    \\    print $result.stdout
    \\  }
    \\
    \\  if $result.exit_code != 0 {
    \\    if ($result.stderr | str length) > 0 {
    \\      print -e $result.stderr
    \\    }
    \\    error make { msg: $"ghq get failed with exit code ($result.exit_code)" }
    \\  }
    \\
    \\  # Diff repo list to find new repos
    \\  let after = (^ghq list --full-path | lines)
    \\  let new_repos = ($after | where { |it| $it not-in $before })
    \\
    \\  # Adopt new repos
    \\  for repo in $new_repos {
    \\    let git_path = ($repo | path join ".git")
    \\    if ($git_path | path type) == "dir" {
    \\      print -e $"gitstore: adopting ($repo)"
    \\      ^gitstore adopt $repo
    \\    }
    \\  }
    \\
    \\  # Handle -u (update) — adopt if not yet adopted
    \\  if ("-u" in $args) {
    \\    let repo_arg = ($args | last)
    \\    let repo_path = (
    \\      ^ghq list --full-path
    \\      | lines
    \\      | where { |it| $it | str contains $repo_arg }
    \\      | last
    \\    )
    \\    if ($repo_path | is-not-empty) {
    \\      let git_path = ($repo_path | path join ".git")
    \\      if ($git_path | path type) == "dir" {
    \\        print -e $"gitstore: adopting ($repo_path)"
    \\        ^gitstore adopt $repo_path
    \\      }
    \\    }
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

pub const bash_hook =
    \\# gitstore-ghq-hook.bash — transparent ghq wrapper with auto-adopt
    \\# Source this file in your .bashrc or .bash_profile
    \\#
    \\# Shadows the ghq command. All subcommands pass through unchanged.
    \\# After "ghq get" (with any flags like -P, -u, --shallow, etc.),
    \\# newly cloned repos are automatically adopted into gitstore.
    \\
    \\ghq() {
    \\  # Pass through if gitstore not available
    \\  if ! command -v gitstore &>/dev/null; then
    \\    command ghq "$@"
    \\    return $?
    \\  fi
    \\
    \\  # For non-get subcommands, just pass through
    \\  if [[ "$1" != "get" ]]; then
    \\    command ghq "$@"
    \\    return $?
    \\  fi
    \\
    \\  # Snapshot repos before clone to detect what's new
    \\  local before
    \\  before="$(command ghq list --full-path)"
    \\
    \\  # Run ghq get with all original flags (-P, -u, --shallow, etc.)
    \\  command ghq "$@"
    \\  local exit_code=$?
    \\
    \\  if [[ $exit_code -ne 0 ]]; then
    \\    return $exit_code
    \\  fi
    \\
    \\  # Diff repo list to find newly cloned repos
    \\  local after
    \\  after="$(command ghq list --full-path)"
    \\
    \\  local new_repos
    \\  new_repos="$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort))"
    \\
    \\  # Adopt any new repos
    \\  if [[ -n "$new_repos" ]]; then
    \\    while IFS= read -r repo_path; do
    \\      if [[ -d "$repo_path/.git" ]]; then
    \\        echo "gitstore: adopting $repo_path" >&2
    \\        command gitstore adopt "$repo_path"
    \\      fi
    \\    done <<< "$new_repos"
    \\  fi
    \\
    \\  # Handle -u (update) — adopt if not yet adopted
    \\  if [[ "$*" == *"-u"* ]]; then
    \\    local repo_arg="${@: -1}"
    \\    local repo_path
    \\    repo_path="$(command ghq list --full-path | grep -F "$repo_arg" | tail -1)"
    \\    if [[ -n "$repo_path" && -d "$repo_path/.git" ]]; then
    \\      echo "gitstore: adopting $repo_path" >&2
    \\      command gitstore adopt "$repo_path"
    \\    fi
    \\  fi
    \\
    \\  return $exit_code
    \\}
;

const testing = @import("std").testing;
const mem = @import("std").mem;

// ===== zsh_hook tests =====

test "zsh hook is non-empty" {
    try testing.expect(zsh_hook.len > 0);
}

test "zsh hook defines ghq function that shadows command" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "ghq()") != null);
}

test "zsh hook has gitstore PATH guard" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "command -v gitstore") != null);
}

test "zsh hook passes through non-get subcommands" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "\"$1\" != \"get\"") != null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "command ghq \"$@\"") != null);
}

test "zsh hook calls gitstore adopt" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "gitstore adopt") != null);
}

test "zsh hook snapshots repo list before clone" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "before=") != null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "after=") != null);
    try testing.expect(mem.indexOf(u8, zsh_hook, "comm -13") != null);
}

test "zsh hook checks .git is directory before adopting" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "-d \"$repo_path/.git\"") != null);
}

test "zsh hook preserves exit code on failure" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "return $exit_code") != null);
}

test "zsh hook uses ghq list for path resolution" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "ghq list --full-path") != null);
}

test "zsh hook handles -u update flag" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "\"-u\"") != null);
}

test "zsh hook adopts in loop for multiple repos" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "while IFS= read -r repo_path") != null);
}

// ===== bash_hook tests =====

test "bash hook is non-empty" {
    try testing.expect(bash_hook.len > 0);
}

test "bash hook defines ghq function that shadows command" {
    try testing.expect(mem.indexOf(u8, bash_hook, "ghq()") != null);
}

test "bash hook has gitstore PATH guard" {
    try testing.expect(mem.indexOf(u8, bash_hook, "command -v gitstore") != null);
}

test "bash hook passes through non-get subcommands" {
    try testing.expect(mem.indexOf(u8, bash_hook, "\"$1\" != \"get\"") != null);
}

test "bash hook snapshots repo list before clone" {
    try testing.expect(mem.indexOf(u8, bash_hook, "before=") != null);
    try testing.expect(mem.indexOf(u8, bash_hook, "comm -13") != null);
}

test "bash hook calls gitstore adopt" {
    try testing.expect(mem.indexOf(u8, bash_hook, "gitstore adopt") != null);
}

test "bash hook checks .git is directory before adopting" {
    try testing.expect(mem.indexOf(u8, bash_hook, "-d \"$repo_path/.git\"") != null);
}

test "bash hook handles -u update flag" {
    try testing.expect(mem.indexOf(u8, bash_hook, "\"-u\"") != null);
}

test "bash hook preserves exit code" {
    try testing.expect(mem.indexOf(u8, bash_hook, "return $exit_code") != null);
}

// ===== rclone_filter tests =====

test "rclone filter is non-empty" {
    try testing.expect(rclone_filter.len > 0);
}

test "rclone filter excludes .git entry and contents" {
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .git\n") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, ".git/**") != null);
}

test "rclone filter excludes .jj entry and contents" {
    try testing.expect(mem.indexOf(u8, rclone_filter, "- .jj\n") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, ".jj/**") != null);
}

test "rclone filter excludes node_modules" {
    try testing.expect(mem.indexOf(u8, rclone_filter, "node_modules/**") != null);
}

test "rclone filter excludes zig-cache" {
    try testing.expect(mem.indexOf(u8, rclone_filter, ".zig-cache/**") != null);
}

test "rclone filter excludes python caches" {
    try testing.expect(mem.indexOf(u8, rclone_filter, "__pycache__/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, ".venv/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, ".pixi/**") != null);
}

test "rclone filter excludes rust target" {
    try testing.expect(mem.indexOf(u8, rclone_filter, "target/**") != null);
}

test "rclone filter excludes secrets" {
    try testing.expect(mem.indexOf(u8, rclone_filter, ".env") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "*.pem") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "*.key") != null);
}

test "rclone filter excludes OS junk" {
    try testing.expect(mem.indexOf(u8, rclone_filter, ".DS_Store") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, "Thumbs.db") != null);
}

test "rclone filter excludes IDE state" {
    try testing.expect(mem.indexOf(u8, rclone_filter, ".idea/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, ".vscode/**") != null);
    try testing.expect(mem.indexOf(u8, rclone_filter, ".cursor/**") != null);
}

test "rclone filter uses exclude syntax" {
    // All rules should start with "- " (rclone exclude) or "#" (comment) or be empty
    var lines = mem.splitScalar(u8, rclone_filter, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(line[0] == '-' or line[0] == '#');
    }
}

// ===== nu_hook tests =====

test "nu hook is non-empty" {
    try testing.expect(nu_hook.len > 0);
}

test "nu hook defines transparent ghq wrapper" {
    try testing.expect(mem.indexOf(u8, nu_hook, "export def --wrapped ghq") != null);
}

test "nu hook exports gitstore-status command" {
    try testing.expect(mem.indexOf(u8, nu_hook, "export def gitstore-status") != null);
}

test "nu hook passes through non-get subcommands" {
    try testing.expect(mem.indexOf(u8, nu_hook, "!= \"get\"") != null);
}

test "nu hook propagates ghq get failure" {
    try testing.expect(mem.indexOf(u8, nu_hook, "error make") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "ghq get failed") != null);
}

test "nu hook uses complete for capturing output" {
    try testing.expect(mem.indexOf(u8, nu_hook, "| complete") != null);
}

test "nu hook snapshots repo list before and after" {
    try testing.expect(mem.indexOf(u8, nu_hook, "let before") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "let after") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "not-in $before") != null);
}

test "nu hook calls gitstore adopt" {
    try testing.expect(mem.indexOf(u8, nu_hook, "^gitstore adopt") != null);
}

test "nu hook checks path type for .git directory" {
    try testing.expect(mem.indexOf(u8, nu_hook, "path type") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "\"dir\"") != null);
}

test "nu hook handles -u update flag" {
    try testing.expect(mem.indexOf(u8, nu_hook, "\"-u\" in $args") != null);
}

test "nu hook uses error make for error handling" {
    try testing.expect(mem.indexOf(u8, nu_hook, "error make") != null);
}

test "nu hook status uses --json flag" {
    try testing.expect(mem.indexOf(u8, nu_hook, "gitstore status --json") != null);
}

test "nu hook status parses from json" {
    try testing.expect(mem.indexOf(u8, nu_hook, "from json") != null);
}

test "nu hook uses nushell pipelines" {
    try testing.expect(mem.indexOf(u8, nu_hook, "| lines") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "| where") != null);
}
