//! root.zig
//!
//! the module root. imports all tests and exposes only the necessary public APIs

const std = @import("std");

const cli_runner = @import("cli_runner.zig");
const command = @import("command.zig");
const group = @import("group.zig");
const context = @import("context.zig");
const parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const fmt = @import("fmt.zig");

pub const Command = command.Command;
pub const Group = group.Group;
pub const Context = context.Context;
pub const testing = cli_runner;

pub const Types = types.Type;
pub const hintedType = types.hintedType;

test {
    _ = @import("cli_runner.zig");
    _ = @import("command.zig");
    _ = @import("group.zig");
    _ = @import("context.zig");
    _ = @import("parser.zig");
    _ = @import("tokenizer.zig");
    _ = @import("types.zig");
    _ = @import("util.zig");
    _ = @import("fmt.zig");
}
