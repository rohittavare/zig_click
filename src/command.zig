//! command.zig
//!
//! Implementation of an executable command that support option & argument specification

const std = @import("std");
const parser = @import("parser.zig");
const util = @import("util.zig");
const types = @import("types.zig");
const tokenizer = @import("tokenizer.zig");
const context = @import("context.zig");
const fmt = @import("fmt.zig");

pub fn Command(comptime name: []const u8, comptime description: []const u8) CommandStruct {
    if (!(comptime parser.validCommandName(name))) @compileError("command name may only contain '-', '_' and alphanumeric characters: " ++ name);
    return CommandStruct{
        .name = name,
        .description = description,
        .parser = .initExhaustive(),
    };
}

/// enables the functional-style construction of a command -- specifying supported options, arguments & handler function
pub const CommandStruct = struct {
    name: []const u8,
    description: []const u8,
    parser: parser.Parser,
    handler_fn: ?*const anyopaque = null,

    arg_help: []const u8 = "",
    opt_help: []const u8 = "",

    const Self = @This();

    // these comptime functions help us construct
    // more complex types based on the parser data shape
    inline fn handler_t(comptime self: Self) type {
        return @Fn([_]type{context.Context} ++ @typeInfo(self.parser.t()).@"struct".field_types, &@as([self.parser.n() + 1]std.builtin.Type.Fn.ParamAttributes, @splat(std.builtin.Type.Fn.ParamAttributes{})), anyerror!void, std.builtin.Type.Fn.Attributes{});
    }
    inline fn handler_ptr_t(comptime self: Self) type {
        return @Pointer(std.builtin.Type.Pointer.Size.one, std.builtin.Type.Pointer.Attributes{ .@"const" = true }, self.handler_t(), null);
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

    pub inline fn argument(comptime self: Self, comptime arg_t: anytype, comptime help: []const u8, comptime cfg: parser.ArgumentConfig(types.CliType.init(arg_t).asRawType())) Self {
        comptime {
            if (self.handler_fn) |_| @compileError("please add arguments before registering the handler function");
            var result = self;
            result.parser = self.parser.addArgument(arg_t, cfg);
            result.arg_help = switch (cfg.kind) {
                .Positional => self.arg_help ++ fmt.argumentHelpText(self.parser.arguments.len, .init(arg_t), help) ++ "\n",
                .Variadic => self.arg_help ++ fmt.argumentHelpText(null, .init(arg_t), help) ++ "\n",
                else => self.arg_help,
            };
            return result;
        }
    }

    /// the handler function should be added *after* any and all options/arguments are registered via the `option`, `flag` and `argument` handlers
    /// the handler's signature should start with a `Context` object, then follow the order of arguments/options registered to the command
    pub inline fn handler(comptime self: Self, comptime handler_fn: self.handler_t()) Self {
        comptime {
            if (self.handler_fn) |_| @compileError("handler function is already registered");
            var result = self;
            result.handler_fn = &handler_fn;
            return result;
        }
    }

    /// an internal method used to run the command with prebuilt context & tokenizer
    /// enabled us to run this command from main or from a test
    pub fn invoke(comptime self: Self, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
        switch (try self.parser.parse(ctx, itr)) {
            .result => |args| {
                if (self.handler_fn) |handler_func| {
                    const handler_f: self.handler_t() = @as(self.handler_ptr_t(), @ptrCast(@alignCast(handler_func))).*;
                    const params = util.prefixTuple(self.parser.t(), context.Context, args, ctx);
                    try @call(std.builtin.CallModifier.auto, handler_f, params);
                }
            },
            .err => |err| {
                try err.print(ctx.stderr);
                try ctx.stderr.print("Try using '--help' to show more information\n", .{});
                try ctx.stderr.flush();
            },
            .help => {
                // perform help message
                const message = comptime message_fmt: {
                    var body: []const u8 = std.fmt.comptimePrint("{s}\n\nUSAGE:\n  {s}{s}{s}\n", .{
                        self.description,
                        self.name,
                        if (self.opt_help.len > 0) " [OPTION]..." else "",
                        if (self.arg_help.len > 0) " [ARG]..." else "",
                    });
                    if (self.arg_help.len > 0) body = body ++ "\nARGUMENTS:\n" ++ self.arg_help;
                    if (self.opt_help.len > 0) body = body ++ "\nOPTIONS:\n" ++ self.opt_help;
                    break :message_fmt body;
                };
                try ctx.stderr.print("{s}\n", .{message});
                try ctx.stderr.flush();
            },
        }
    }

    /// use this function to invoke this command in your script's main function
    pub fn main(comptime self: Self, init: std.process.Init) !void {
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
