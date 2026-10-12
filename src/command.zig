//! Implementation of an executable command that support option & argument specification

const std = @import("std");
const parser = @import("parser.zig");
const util = @import("util.zig");
const types = @import("types.zig");
const tokenizer = @import("tokenizer.zig");
const context = @import("context.zig");
const fmt = @import("fmt.zig");

// const EmptyCommandType = CommandStruct(struct {});
// pub fn Command(comptime name: []const u8, comptime description: []const u8) EmptyCommandType {
//     return EmptyCommandType{ .name = name, .description = description, .parser = parser.ExhaustiveParser };
// }

// fn CommandStruct(comptime t: type) type {
//     return struct {
//         name: []const u8,
//         description: []const u8,
//         parser: parser.Parser(T),
//         handler_fn: ?HandlerT = null,
//
//         const Self = @This();
//         const T = t;
//         const HandlerT = @Fn([_]type{context.Context} ++ @typeInfo(T).@"struct".field_types, &@as([N + 1]std.builtin.Type.Fn.ParamAttributes, @splat(std.builtin.Type.Fn.ParamAttributes{})), error{}!void, std.builtin.Type.Fn.Attributes{});
//         const N = @typeInfo(t).@"struct".field_names.len;
//
//         pub inline fn option(comptime self: Self, comptime declaration: []const u8, comptime opT: type, comptime def: opT) CommandStruct(util.extendTupleType(T, opT)) {
//             if (self.handler_fn) |_| @compileError("please add options before registering the handler function");
//             return CommandStruct(util.extendTupleType(T, opT)){
//                 .name = self.name,
//                 .description = self.description,
//                 .parser = self.parser.addOption(declaration, opT, def),
//                 .handler_fn = self.handler_fn,
//             };
//         }
//
//         pub inline fn flag(comptime self: Self, comptime declaration: []const u8) CommandStruct(util.extendTupleType(T, bool)) {
//             if (self.handler_fn) |_| @compileError("please add flags before registering the handler function");
//             return CommandStruct(util.extendTupleType(T, bool)){
//                 .name = self.name,
//                 .description = self.description,
//                 .parser = self.parser.addFlag(declaration),
//                 .handler_fn = self.handler_fn,
//             };
//         }
//
//         pub inline fn argument(comptime self: Self, comptime argT: type) CommandStruct(util.extendTupleType(T, argT)) {
//             if (self.handler_fn) |_| @compileError("please add arguments before registering the handler function");
//             return CommandStruct(util.extendTupleType(T, bool)){
//                 .name = self.name,
//                 .description = self.description,
//                 .parser = self.parser.addArgument(argT),
//                 .handler_fn = self.handler_fn,
//             };
//         }
//
//         pub inline fn handler(comptime self: Self, comptime handler_fn: HandlerT) Self {
//             if (self.handler_fn) |_| @compileError("handler function is already registered");
//             return Self{
//                 .name = self.name,
//                 .description = self.description,
//                 .parser = self.parser,
//                 .handler_fn = handler_fn,
//             };
//         }
//
//         pub fn invoke(comptime self: Self, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
//             if (try self.parser.parse(itr)) |args| {
//                 if (self.handler_fn) |handler_func| {
//                     var params: HandlerT = undefined;
//                     @field(params, @typeInfo(HandlerT).@"struct".field_names[0]) = ctx;
//                     inline for (@typeInfo(HandlerT).@"struct".field_names[1..], @typeInfo(T).@"struct".field_names) |df, sf| {
//                         @field(params, df) = @field(args, sf);
//                     }
//                     try @call(std.builtin.CallModifier.auto, handler_func, params);
//                 }
//             } else {
//                 // perform help message
//             }
//         }
//
//         pub fn main(comptime self: Self, init: std.process.Init) !void {
//             const io = init.io;
//
//             var args = init.minimal.args.iterate();
//             if (!args.skip()) @panic("malformed args: missing self argument!\n");
//
//             var stdin_buf: [1024]u8 = undefined;
//             var stdin = std.Io.File.stdin().reader(init.io, &stdin_buf);
//             const stdin_reader = &stdin.interface;
//
//             var stdout_buf: [1024]u8 = undefined;
//             var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
//             const stdout_writer = &stdout.interface;
//
//             var stderr_buf: [1024]u8 = undefined;
//             var stderr = std.Io.File.stdout().writer(io, &stderr_buf);
//             const stderr_writer = &stderr.interface;
//
//             const ctx = context.Context.initForProcess(init, stdin_reader, stdout_writer, stderr_writer);
//
//             try self.invoke(ctx, tokenizer.Tokenizer{ .argsIterator = &args });
//         }
//     };
// }

pub fn Command(comptime name: []const u8, comptime description: []const u8) CommandStruct {
    if (!(comptime parser.validCommandName(name))) @compileError("command name may only contain '-', '_' and alphanumeric characters: " ++ name);
    return CommandStruct{
        .name = name,
        .description = description,
        .parser = parser.ExhaustiveParser(),
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
    inline fn n(comptime self: Self) usize {
        return @typeInfo(self.parser.t).@"struct".field_names.len;
    }
    inline fn handlerT(comptime self: Self) type {
        return @Fn([_]type{context.Context} ++ @typeInfo(self.parser.t).@"struct".field_types, &@as([self.n() + 1]std.builtin.Type.Fn.ParamAttributes, @splat(std.builtin.Type.Fn.ParamAttributes{})), anyerror!void, std.builtin.Type.Fn.Attributes{});
    }
    inline fn handlerPtrT(comptime self: Self) type {
        const handler_t = self.handlerT();
        return @Pointer(std.builtin.Type.Pointer.Size.one, std.builtin.Type.Pointer.Attributes{ .@"const" = true }, handler_t, null);
    }

    pub inline fn option(comptime self: Self, comptime declaration: []const u8, comptime opT: type, comptime def: opT, comptime help: []const u8) Self {
        if (self.handler_fn) |_| @compileError("please add options before registering the handler function");
        return CommandStruct{
            .name = self.name,
            .description = self.description,
            .parser = self.parser.addOption(declaration, opT, def),
            .handler_fn = self.handler_fn,
            .opt_help = self.opt_help ++ fmt.optionHelpText(declaration, opT, help) ++ "\n",
            .arg_help = self.arg_help,
        };
    }

    pub inline fn flag(comptime self: Self, comptime declaration: []const u8, comptime help: []const u8) Self {
        if (self.handler_fn) |_| @compileError("please add flags before registering the handler function");
        return CommandStruct{
            .name = self.name,
            .description = self.description,
            .parser = self.parser.addFlag(declaration),
            .handler_fn = self.handler_fn,
            .opt_help = self.opt_help ++ fmt.flagHelpText(declaration, help) ++ "\n",
            .arg_help = self.arg_help,
        };
    }

    pub inline fn argument(comptime self: Self, comptime argT: type, comptime help: []const u8) Self {
        if (self.handler_fn) |_| @compileError("please add arguments before registering the handler function");
        return CommandStruct{
            .name = self.name,
            .description = self.description,
            .parser = self.parser.addArgument(argT),
            .handler_fn = self.handler_fn,
            .opt_help = self.opt_help,
            .arg_help = self.arg_help ++ fmt.argumentHelpText(self.parser.arguments.len, argT, help) ++ "\n",
        };
    }

    /// the handler function should be added *after* any and all options/arguments are registered via the `option`, `flag` and `argument` handlers
    /// the handler's signature should start with a `Context` object, then follow the order of arguments/options registered to the command
    pub inline fn handler(comptime self: Self, comptime handler_fn: self.handlerT()) Self {
        if (self.handler_fn) |_| @compileError("handler function is already registered");
        return Self{
            .name = self.name,
            .description = self.description,
            .parser = self.parser,
            .handler_fn = &handler_fn,
            .opt_help = self.opt_help,
            .arg_help = self.arg_help,
        };
    }

    /// an internal method used to run the command with prebuilt context & tokenizer
    /// enabled us to run this command from main or from a test
    pub fn invoke(comptime self: Self, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
        if (self.parser.parse(itr)) |maybe_args| {
            if (maybe_args) |args| {
                if (self.handler_fn) |handler_func| {
                    const handler_f: self.handlerT() = @as(self.handlerPtrT(), @ptrCast(@alignCast(handler_func))).*;
                    const params = util.prefixTuple(self.parser.t, context.Context, args, ctx);
                    try @call(std.builtin.CallModifier.auto, handler_f, params);
                }
            } else {
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
            }
        } else |_| {
            std.debug.print("Try using '--help' to show more information\n", .{});
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
