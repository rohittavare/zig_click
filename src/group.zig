//! group.zig
//!
//! implementation of a command group, which multiplexes multiple defined commands
//! does not yet support group-level option or handler

const std = @import("std");
const parser = @import("parser.zig");
const cmd = @import("command.zig");
const util = @import("util.zig");
const context = @import("context.zig");
const tokenizer = @import("tokenizer.zig");
const fmt = @import("fmt.zig");
const types = @import("types.zig");

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

    pub fn name(self: CommandOrGroup) []const u8 {
        return switch (self) {
            .command => |c| c.name,
            .group => |g| g.name,
        };
    }

    pub fn description(self: CommandOrGroup) []const u8 {
        return switch (self) {
            .command => |c| c.description,
            .group => |g| g.description,
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
    if (!(comptime parser.validCommandName(name))) @compileError("group name may only contain '-', '_' and alphanumeric characters: " ++ name);
    return GroupStruct{
        .name = name,
        .description = description,
        .parser = .initNonExhaustive(),
        .command_idx = std.StaticStringMap(usize).initComptime(.{}),
        .commands = &.{},
    };
}

pub const GroupStruct = struct {
    name: []const u8,
    description: []const u8,
    parser: parser.Parser,
    command_idx: std.StaticStringMap(usize),
    commands: []const CommandOrGroup,
    handler_fn: ?*const anyopaque = null,

    opt_help: []const u8 = "",

    const Self = @This();

    inline fn handler_t(comptime self: Self) type {
        return @Fn([_]type{context.Context} ++ @typeInfo(self.parser.t()).@"struct".field_types, &@as([self.parser.n() + 1]std.builtin.Type.Fn.ParamAttributes, @splat(std.builtin.Type.Fn.ParamAttributes{})), anyerror!void, std.builtin.Type.Fn.Attributes{});
    }
    inline fn handler_ptr_t(comptime self: Self) type {
        return @Pointer(std.builtin.Type.Pointer.Size.one, std.builtin.Type.Pointer.Attributes{ .@"const" = true }, self.handler_t(), null);
    }

    pub inline fn subcommand(comptime self: GroupStruct, comptime command_struct: cmd.CommandStruct) GroupStruct {
        comptime {
            if (self.handler_fn) |_| @compileError("please add arguments before registering the handler function");
            if (self.command_idx.has(command_struct.name)) @compileError("already registered subcommand/subgroup of name \"" ++ command_struct.name ++ "\"");
            var result = self;
            result.command_idx = util.insertStaticStringMapComptime(usize, self.command_idx, .{ command_struct.name, self.commands.len });
            result.commands = util.extendSliceComptime(CommandOrGroup, self.commands, CommandOrGroup.init(command_struct));
            return result;
        }
    }

    // maybe we should have a single method for adding both commands and groups?
    pub inline fn subgroup(comptime self: GroupStruct, comptime group_struct: GroupStruct) GroupStruct {
        comptime {
            if (self.handler_fn) |_| @compileError("please add arguments before registering the handler function");
            if (self.command_idx.has(group_struct.name)) @compileError("already registered subcommand/subgroup of name \"" ++ group_struct.name ++ "\"");
            var result = self;
            result.command_idx = util.insertStaticStringMapComptime(usize, self.command_idx, .{ group_struct.name, self.commands.len });
            result.commands = util.extendSliceComptime(CommandOrGroup, self.commands, CommandOrGroup.init(group_struct));
            return result;
        }
    }

    pub inline fn option(comptime self: Self, comptime op_t: anytype, comptime help: []const u8, comptime cfg: parser.OptionConfig(types.CliType.init(op_t).asRawType())) Self {
        comptime {
            if (self.handler_fn) |_| @compileError("please add options before registering the handler function");
            var result = self;
            result.parser = self.parser.addOption(op_t, cfg);
            result.opt_help = self.opt_help ++ fmt.optionHelpText(cfg.long, cfg.short, .init(op_t), help) ++ "\n";
            return result;
        }
    }

    pub inline fn flag(comptime self: Self, comptime help: []const u8, comptime cfg: parser.FlagConfig) Self {
        comptime {
            if (self.handler_fn) |_| @compileError("please add flags before registering the handler function");
            var result = self;
            result.parser = self.parser.addFlag(cfg);
            result.opt_help = self.opt_help ++ fmt.flagHelpText(cfg.long, cfg.short, help) ++ "\n";
            return result;
        }
    }

    pub inline fn handler(comptime self: GroupStruct, comptime handler_fn: self.handler_t()) GroupStruct {
        comptime {
            if (self.handler_fn) |_| @compileError("handler function is already registered");
            var result = self;
            result.handler_fn = &handler_fn;
            return result;
        }
    }

    pub fn invoke(comptime self: GroupStruct, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
        if (self.commands.len == 0) @compileError("attempting to invoke command group '" ++ self.name ++ "' without any subcommands registered");
        var chosen_cmd: [self.commands.len]bool = @splat(false);
        const prsr = self.parser.addArgument(types.Type.COMMAND, .{});
        switch (try prsr.parse(ctx, itr)) {
            .result => |result| {
                const cmd_name: []const u8 = @field(result, @typeInfo(@TypeOf(result)).@"struct".field_names[self.parser.n()]);
                if (self.command_idx.get(cmd_name)) |cmd_idx| {
                    if (self.handler_fn) |opaque_handler_fn| {
                        const handler_fn = @as(self.handler_ptr_t(), @ptrCast(@alignCast(opaque_handler_fn))).*;
                        const params = util.prefixTuple(self.parser.t(), context.Context, util.truncateTuple(prsr.t(), result), ctx);
                        try @call(.auto, handler_fn, params);
                    }
                    chosen_cmd[cmd_idx] = true;
                    inline for (self.commands, chosen_cmd) |com, should_run| {
                        if (should_run) try com.invoke(ctx, itr);
                    }
                } else {
                    try ctx.stderr.print("error: unrecognized command '{s}'\n", .{cmd_name});
                    try ctx.stderr.print("Try using '--help' to show more information\n", .{});
                    try ctx.stderr.flush();
                }
            },
            .err => |err| switch (err) {
                .MissingPositionalArgument => |i| {
                    if (i == self.parser.arguments.len) {
                        try ctx.stderr.print("error: please specify a subcommand\n", .{});
                    } else {
                        try err.print(ctx.stderr);
                    }
                    try ctx.stderr.print("Try using '--help' to show more information\n", .{});
                    try ctx.stderr.flush();
                },
                else => {
                    try err.print(ctx.stderr);
                    try ctx.stderr.print("Try using '--help' to show more information\n", .{});
                    try ctx.stderr.flush();
                },
            },
            .help => {
                // perform help message
                const message = comptime message_fmt: {
                    var body: []const u8 = std.fmt.comptimePrint("{s}\n\nUSAGE:\n  {s}{s} [COMMAND]\n\nCOMMANDS:\n", .{
                        self.description,
                        self.name,
                        if (self.opt_help.len > 0) " [OPTION]..." else "",
                    });
                    for (self.commands) |command| {
                        body = body ++ fmt.commandHelpText(command.name(), command.description()) ++ "\n";
                    }
                    if (self.opt_help.len > 0) body = body ++ "\nOPTIONS:\n" ++ self.opt_help;
                    break :message_fmt body;
                };
                try ctx.stderr.print("{s}\n", .{message});
                try ctx.stderr.flush();
            },
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
