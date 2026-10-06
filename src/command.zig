//! Implementation of an executable command that support option & argument specification

const std = @import("std");
const parser = @import("parser.zig");
const util = @import("util.zig");
const types = @import("types.zig");
const tokenizer = @import("tokenizer.zig");
const context = @import("context.zig");

const EmptyCommandType = CommandStruct(struct {});
pub fn Command(comptime name: []const u8, comptime description: []const u8) EmptyCommandType {
    return EmptyCommandType{ .name = name, .description = description, .parser = parser.ExhaustiveParser };
}

fn CommandStruct(comptime t: type) type {
    return struct {
        name: []const u8,
        description: []const u8,
        parser: parser.Parser(T),
        handler_fn: ?HandlerT = null,

        const Self = @This();
        const T = t;
        const HandlerT = @Fn([_]type{context.Context} ++ @typeInfo(T).@"struct".field_types, &@as([N + 1]std.builtin.Type.Fn.ParamAttributes, @splat(std.builtin.Type.Fn.ParamAttributes{})), error{}!void, std.builtin.Type.Fn.Attributes{});
        const N = @typeInfo(t).@"struct".field_names.len;

        pub inline fn option(comptime self: Self, comptime declaration: []const u8, comptime opT: type, comptime def: opT) CommandStruct(util.extendTupleType(T, opT)) {
            if (self.handler_fn) |_| @compileError("please add options before registering the handler function");
            return CommandStruct(util.extendTupleType(T, opT)){
                .name = self.name,
                .description = self.description,
                .parser = self.parser.addOption(declaration, opT, def),
                .handler_fn = self.handler_fn,
            };
        }

        pub inline fn flag(comptime self: Self, comptime declaration: []const u8) CommandStruct(util.extendTupleType(T, bool)) {
            if (self.handler_fn) |_| @compileError("please add flags before registering the handler function");
            return CommandStruct(util.extendTupleType(T, bool)){
                .name = self.name,
                .description = self.description,
                .parser = self.parser.addFlag(declaration),
                .handler_fn = self.handler_fn,
            };
        }

        pub inline fn argument(comptime self: Self, comptime argT: type) CommandStruct(util.extendTupleType(T, argT)) {
            if (self.handler_fn) |_| @compileError("please add arguments before registering the handler function");
            return CommandStruct(util.extendTupleType(T, bool)){
                .name = self.name,
                .description = self.description,
                .parser = self.parser.addArgument(argT),
                .handler_fn = self.handler_fn,
            };
        }

        pub inline fn handler(comptime self: Self, comptime handler_fn: HandlerT) Self {
            if (self.handler_fn) |_| @compileError("handler function is already registered");
            return Self{
                .name = self.name,
                .description = self.description,
                .parser = self.parser,
                .handler_fn = handler_fn,
            };
        }

        pub fn invoke(comptime self: Self, ctx: context.Context, itr: tokenizer.Tokenizer) !void {
            if (try self.parser.parse(itr)) |args| {
                if (self.handler_fn) |handler_func| {
                    var params: HandlerT = undefined;
                    @field(params, @typeInfo(HandlerT).@"struct".field_names[0]) = ctx;
                    inline for (@typeInfo(HandlerT).@"struct".field_names[1..], @typeInfo(T).@"struct".field_names) |df, sf| {
                        @field(params, df) = @field(args, sf);
                    }
                    try @call(std.builtin.CallModifier.auto, handler_func, params);
                }
            } else {
                // perform help message
            }
        }

        pub fn main(comptime self: Self, init: std.process.Init) !void {
            var args = init.minimal.args.iterate();
            if (!args.skip()) @panic("malformed args: missing self argument!\n");

            try self.invoke(context.Context.init(init), tokenizer.Tokenizer{ .argsIterator = &args });
        }
    };
}
