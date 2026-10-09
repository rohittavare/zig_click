//! Implementation of an executable command that support option & argument specification

const std = @import("std");
const parser = @import("parser.zig");
const util = @import("util.zig");
const types = @import("types.zig");
const tokenizer = @import("tokenizer.zig");
const context = @import("context.zig");

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
    return CommandStruct{
        .t = struct {},
        .name = name,
        .description = description,
        .parser = parser.ExhaustiveParser(),
    };
}

pub const CommandStruct = struct {
    t: type,
    name: []const u8,
    description: []const u8,
    parser: parser.Parser,
    handler_fn: ?*anyopaque = null,

    const Self = @This();

    inline fn n(comptime self: Self) usize {
        return @typeInfo(self.t).@"struct".field_names.len;
    }
    inline fn handlerT(comptime self: Self) type {
        return @Fn([_]type{context.Context} ++ @typeInfo(self.t).@"struct".field_types, &@as([self.n() + 1]std.builtin.Type.Fn.ParamAttributes, @splat(std.builtin.Type.Fn.ParamAttributes{})), error{}!void, std.builtin.Type.Fn.Attributes{});
    }

    pub inline fn option(comptime self: Self, comptime declaration: []const u8, comptime opT: type, comptime def: opT) Self {
        if (self.handler_fn) |_| @compileError("please add options before registering the handler function");
        return Command{
            .t = util.extendTupleType(self.t, opT),
            .name = self.name,
            .description = self.description,
            .parser = self.parser.addOption(declaration, opT, def),
            .handler_fn = self.handler_fn,
        };
    }

    pub inline fn flag(comptime self: Self, comptime declaration: []const u8) Self {
        if (self.handler_fn) |_| @compileError("please add flags before registering the handler function");
        return Command{
            .t = util.extendTupleType(self.t, bool),
            .name = self.name,
            .description = self.description,
            .parser = self.parser.addFlag(declaration),
            .handler_fn = self.handler_fn,
        };
    }

    pub inline fn argument(comptime self: Self, comptime argT: type) Self {
        if (self.handler_fn) |_| @compileError("please add arguments before registering the handler function");
        return Command{
            .t = util.extendTupleType(self.t, argT),
            .name = self.name,
            .description = self.description,
            .parser = self.parser.addArgument(argT),
            .handler_fn = self.handler_fn,
        };
    }

    pub inline fn handler(comptime self: Self, comptime handler_fn: self.handlerT()) Self {
        if (self.handler_fn) |_| @compileError("handler function is already registered");
        return Self{
            .t = self.t,
            .name = self.name,
            .description = self.description,
            .parser = self.parser,
            .handler_fn = &handler_fn,
        };
    }

    pub fn invoke(comptime self: Self, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
        if (try self.parser.parse(itr)) |args| {
            if (self.handler_fn) |handler_func| {
                const handler_f = @as(*self.handlerT(), @ptrCast(@alignCast(handler_func))).*;
                const params = util.prefixTuple(self.t, context.Context, args, ctx);
                try @call(std.builtin.CallModifier.auto, handler_f, params);
            }
        } else {
            // perform help message
        }
    }

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
