//! Public entry for libgitstore.
//!
//! Consumers import this as:
//!   const gitstore = @import("gitstore");
//!   _ = gitstore.url.parse(...);
//!   _ = gitstore.clone.cloneMany(...);
//!   _ = gitstore.list.walk(...);
//!   // existing gitstore.zig surface also re-exported flat:
//!   _ = gitstore.adopt(...);
//!   _ = gitstore.verify(...);

const std = @import("std");

pub const url = @import("url.zig");
pub const config = @import("config.zig");
pub const list = @import("list.zig");
pub const cache = @import("cache.zig");
pub const clone = @import("clone.zig");
pub const exec = @import("exec.zig");
pub const log = @import("log.zig");
pub const hooks = @import("hooks.zig");

// Existing gitstore.zig surface — re-exported flat for back-compat.
const gs = @import("gitstore.zig");
pub const adopt = gs.adopt;
pub const adoptAll = gs.adoptAll;
pub const detach = gs.detach;
pub const detachAll = gs.detachAll;
pub const verify = gs.verify;
pub const verifyAll = gs.verifyAll;
pub const status = gs.status;
pub const sync = gs.sync;
pub const init = gs.init;
pub const initRepo = gs.initRepo;
pub const isAdopted = gs.isAdopted;
pub const repoRelativePath = gs.repoRelativePath;
pub const repoStoragePath = gs.repoStoragePath;
pub const enumerateLinkedWorktrees = gs.enumerateLinkedWorktrees;
pub const freeWorktreePaths = gs.freeWorktreePaths;
pub const rewriteJjGitTarget = gs.rewriteJjGitTarget;
pub const rewriteJjGitTargetRelative = gs.rewriteJjGitTargetRelative;

test "lib: public url parser smoke" {
    const gpa = std.testing.allocator;
    var spec = try url.parse(gpa, "github.com/EugOT/gitstore-cli", .{});
    defer spec.deinit(gpa);

    try std.testing.expectEqualStrings("github.com", spec.host);
    try std.testing.expectEqualStrings("EugOT", spec.owner);
    try std.testing.expectEqualStrings("gitstore-cli", spec.name);
}
