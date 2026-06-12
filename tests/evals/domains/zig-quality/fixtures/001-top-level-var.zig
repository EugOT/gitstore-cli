const std = @import("std");

var mutable_global: usize = 0;

pub fn main(init: std.process.Init) !u8 {
    _ = init;
    mutable_global += 1;
    return 0;
}
