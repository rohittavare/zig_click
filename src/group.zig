const std = @import("std");
const parser = @import("parser.zig");
const cmd = @import("command.zig");
const util = @import("util.zig");
const context = @import("context.zig");
const tokenizer = @import("tokenizer.zig");

pub const CommandOrGroup = union(enum) {
    command: *const cmd.CommandStruct,
    group: *const GroupStruct,

    pub inline fn init(comptime command_or_group: anytype) CommandOrGroup {
        return switch (@TypeOf(command_or_group)) {
            cmd.CommandStruct => CommandOrGroup{ .command = &command_or_group },
            GroupStruct => CommandOrGroup{ .group = &command_or_group },
            CommandOrGroup => command_or_group,
            else => |t| @compileError("expected CommandStruct or GroupStruct. found: " ++ @typeName(t)),
        };
    }

    pub fn invoke(comptime self: CommandOrGroup, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
        switch (self) {
            .command => |c| try c.invoke(ctx, itr),
            .group => |g| try g.invoke(ctx, itr),
        }
    }
};

pub inline fn Group(comptime name: []const u8, comptime description: []const u8) GroupStruct {
    return GroupStruct{
        .name = name,
        .description = description,
        .command_idx = std.StaticStringMap(usize).initComptime(.{}),
        .commands = &.{},
    };
}

pub const GroupStruct = struct {
    name: []const u8,
    description: []const u8,
    command_idx: std.StaticStringMap(usize),
    commands: []const CommandOrGroup,

    pub inline fn subcommand(comptime self: GroupStruct, comptime command_struct: cmd.CommandStruct) GroupStruct {
        return GroupStruct{
            .name = self.name,
            .description = self.description,
            .command_idx = util.insertStaticStringMapComptime(usize, self.command_idx, .{ command_struct.name, self.commands.len }),
            .commands = util.extendSliceComptime(CommandOrGroup, self.commands, CommandOrGroup.init(command_struct)),
        };
    }

    // maybe we should have a single method for adding both commands and groups?
    pub inline fn subgroup(comptime self: GroupStruct, comptime group_struct: GroupStruct) GroupStruct {
        return GroupStruct{
            .name = self.name,
            .description = self.description,
            .command_idx = util.insertStaticStringMapComptime(usize, self.command_idx, .{ group_struct.name, self.commands.len }),
            .commands = util.extendSliceComptime(CommandOrGroup, self.commands, CommandOrGroup.init(group_struct)),
        };
    }

    pub fn invoke(comptime self: GroupStruct, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
        var chosen_cmd: [self.commands.len]bool = @splat(false);
        const prsr = parser.NonExhaustiveParser().addArgument([]const u8);
        if (try prsr.parse(itr)) |args| {
            if (self.command_idx.get(args.@"0")) |cmd_idx| {
                chosen_cmd[cmd_idx] = true;
                inline for (self.commands, chosen_cmd) |com, should_run| {
                    if (should_run) try com.invoke(ctx, itr);
                }
            } else {
                // TODO: better error message here
                @panic("unrecognized command!");
            }
        } else {
            // TODO: perform help message
        }
    }

    pub fn main(comptime self: GroupStruct, init: std.process.Init) !void {
        const io = init.io;

        var args = init.minimal.args.iterate();
        if (!args.skip()) @panic("malformed args: missing self argument!\n");

        var stdin_buf: [1024]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(init.io, &stdin_buf);
        const stdin_reader = &stdin.interface;

        var stdout_buf: [1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
        const stdout_writer = &stdout.interface;

        var stderr_buf: [1024]u8 = undefined;
        var stderr = std.Io.File.stdout().writer(io, &stderr_buf);
        const stderr_writer = &stderr.interface;

        const ctx = context.Context.initForProcess(init, stdin_reader, stdout_writer, stderr_writer);

        try self.invoke(ctx, tokenizer.Tokenizer{ .argsIterator = &args });
    }
};
