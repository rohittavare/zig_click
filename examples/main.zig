const std = @import("std");
const click = @import("zig_click");

const base_64 = @import("base_64.zig");

const examples = click.Group("examples", "example scripts utilizing the `zig_click` library")
    .subgroup(base_64.base_64);
pub fn main(init: std.process.Init) !void {
    try examples.main(init);
}
