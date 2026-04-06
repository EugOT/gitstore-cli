/// Shell hook string literals for zsh and nushell.
/// Printed to stdout by "gitstore hook --zsh" and "gitstore hook --nu".

pub const zsh_hook =
    \\# gitstore-ghq-hook.zsh — auto-adopt repos after ghq get
    \\# Source this file in your .zshrc or place it in ~/.config/zsh/functions/
    \\
    \\ghq-get() {
    \\  if ! command -v gitstore &>/dev/null; then
    \\    echo "gitstore: not found in PATH, skipping auto-adopt" >&2
    \\    command ghq get "$@"
    \\    return $?
    \\  fi
    \\
    \\  # Capture ghq output to find the cloned path
    \\  local ghq_root
    \\  ghq_root="$(command ghq root)"
    \\
    \\  # Run ghq get, passing through all arguments
    \\  command ghq get "$@"
    \\  local exit_code=$?
    \\
    \\  if [[ $exit_code -ne 0 ]]; then
    \\    return $exit_code
    \\  fi
    \\
    \\  # Find the repo that was just cloned.
    \\  # ghq get prints the repo path relative to root on success.
    \\  # Parse the last argument as the repo identifier and resolve it.
    \\  local repo_arg="${@: -1}"
    \\  local repo_path
    \\
    \\  # Try to find the repo in ghq list matching the argument
    \\  repo_path="$(command ghq list --full-path | grep -F "$repo_arg" | tail -1)"
    \\
    \\  if [[ -z "$repo_path" ]]; then
    \\    # Fallback: try exact match with ghq root
    \\    repo_path="$ghq_root/$repo_arg"
    \\  fi
    \\
    \\  if [[ -d "$repo_path/.git" ]]; then
    \\    echo "gitstore: adopting $repo_path" >&2
    \\    command gitstore adopt "$repo_path"
    \\  fi
    \\}
;

pub const nu_hook =
    \\# gitstore.nu — nushell module for gitstore integration
    \\# Usage: use gitstore.nu
    \\
    \\# Wrap ghq get with automatic gitstore adoption
    \\export def ghq-get [...args: string] {
    \\  let ghq_root = (^ghq root | str trim)
    \\
    \\  # Run ghq get, passing through all arguments
    \\  let result = (do { ^ghq get ...$args } | complete)
    \\
    \\  if $result.exit_code != 0 {
    \\    print -e $result.stderr
    \\    error make { msg: $"ghq get failed with exit code ($result.exit_code)" }
    \\  }
    \\
    \\  if ($result.stdout | str length) > 0 {
    \\    print $result.stdout
    \\  }
    \\
    \\  # Find the repo that was just cloned
    \\  let repo_arg = ($args | last)
    \\  let repo_path = (
    \\    ^ghq list --full-path
    \\    | lines
    \\    | where { |it| $it | str contains $repo_arg }
    \\    | last
    \\  )
    \\
    \\  if ($repo_path | is-empty) {
    \\    print -e "gitstore: could not determine cloned repo path"
    \\    return
    \\  }
    \\
    \\  # Check if .git is still a directory (not yet adopted)
    \\  let git_path = ($repo_path | path join ".git")
    \\  if ($git_path | path type) == "dir" {
    \\    print -e $"gitstore: adopting ($repo_path)"
    \\    ^gitstore adopt $repo_path
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

const testing = @import("std").testing;
const mem = @import("std").mem;

// ===== zsh_hook tests =====

test "zsh hook is non-empty" {
    try testing.expect(zsh_hook.len > 0);
}

test "zsh hook defines ghq-get function" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "ghq-get()") != null);
}

test "zsh hook has gitstore PATH guard" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "command -v gitstore") != null);
}

test "zsh hook calls ghq get" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "command ghq get") != null);
}

test "zsh hook calls gitstore adopt" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "gitstore adopt") != null);
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

test "zsh hook has fallback path resolution" {
    try testing.expect(mem.indexOf(u8, zsh_hook, "$ghq_root/$repo_arg") != null);
}

// ===== nu_hook tests =====

test "nu hook is non-empty" {
    try testing.expect(nu_hook.len > 0);
}

test "nu hook exports ghq-get command" {
    try testing.expect(mem.indexOf(u8, nu_hook, "export def ghq-get") != null);
}

test "nu hook exports gitstore-status command" {
    try testing.expect(mem.indexOf(u8, nu_hook, "export def gitstore-status") != null);
}

test "nu hook uses complete for capturing output" {
    try testing.expect(mem.indexOf(u8, nu_hook, "| complete") != null);
}

test "nu hook calls ghq get with spread args" {
    try testing.expect(mem.indexOf(u8, nu_hook, "^ghq get ...$args") != null);
}

test "nu hook calls gitstore adopt" {
    try testing.expect(mem.indexOf(u8, nu_hook, "^gitstore adopt") != null);
}

test "nu hook checks path type for .git directory" {
    try testing.expect(mem.indexOf(u8, nu_hook, "path type") != null);
    try testing.expect(mem.indexOf(u8, nu_hook, "\"dir\"") != null);
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
