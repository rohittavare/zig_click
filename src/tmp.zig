const std = @import("std");

const OptParseState = union(enum) {
    DashPrefix: usize,
    Name: []const u8,

    const init = OptParseState{ .DashPrefix = 0 };
};

const @"/" = &[_]u8{'/'};
const @"-" = &[_]u8{'-'};
fn approx_flags_ct(opt: []const u8) usize {
    return std.mem.count(u8, opt, @"/") + 1;
}

const EmptyCmdType = Command(struct {});
fn Cmd(comptime name: []const u8) EmptyCmdType {
    return EmptyCmdType{
        .name = name,
        .options = &[_][]const u8{},
        .arguments = &[_][]const u8{},
    };
}

fn Command(comptime t: type) type {
    const n = @typeInfo(t).@"struct".field_types.len;
    const handler_fn_attrs: [n]std.builtin.Type.Fn.ParamAttributes = @splat(.{});
    const handler_fn_type = @Fn(@typeInfo(t).@"struct".field_types, &handler_fn_attrs, error{}!void, .{});

    return struct {
        name: []const u8,
        options: []const []const u8,
        arguments: []const []const u8,
        handler_fn: ?F = null,

        const T = t;
        const N = n;
        const F = handler_fn_type;
        const Self = @This();

        fn appendType(comptime ty: type) type {
            const field_types = @typeInfo(Self.T).@"struct".field_types;
            return @Tuple(&(field_types.* ++ [_]type{ty}));
        }

        fn option(comptime self: Self, comptime opt: []const u8, comptime ty: type) Command(appendType(ty)) {
            comptime {
                var ret: [approx_flags_ct(opt)][]const u8 = undefined;
                var idx: usize = 0;
                var parse_state: OptParseState = .init;
                for (opt, 0..) |c, i| switch (parse_state) {
                    .DashPrefix => |s| {
                        switch (c) {
                            '-' => {
                                if (s == 2) @compileError("option names must be prefixed with `-' or `--'");
                                parse_state = OptParseState{ .DashPrefix = s + 1 };
                            },
                            'a'...'z', 'A'...'Z', '0'...'9' => {
                                if (s == 0) @compileError("option names must be prefixed with `-' or `--'");
                                parse_state = OptParseState{ .Name = opt[(i - s)..(i + 1)] };
                            },
                            else => {
                                if (s == 0) @compileError("option names must be prefixed with `-' or `--'");
                                @compileError("option names must start with a-z, A-Z or 0-9");
                            },
                        }
                    },
                    .Name => |name| {
                        switch (c) {
                            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {
                                parse_state = OptParseState{ .Name = opt[(i - name.len)..(i + 1)] };
                            },
                            '/' => {
                                ret[idx] = name;
                                idx += 1;
                                parse_state = .init;
                            },
                            else => @compileError("option names may only contain a-z, A-Z, 0-9, - or _ characters"),
                        }
                    },
                };
                switch (parse_state) {
                    .DashPrefix => @compileError("option name is missing or incomplete"),
                    .Name => |name| {
                        ret[idx] = name;
                    },
                }
                return Command(appendType(ty)){ .name = self.name, .arguments = self.arguments, .options = &(self.options.* ++ [_][]const u8{opt}) };
            }
        }

        fn argument(comptime self: Self, comptime arg: []const u8, comptime ty: type) Command(appendType(ty)) {
            return Command(appendType(ty)){ .name = self.name, .arguments = &(self.arguments.* ++ [_][]const u8{arg}), .options = self.options };
        }

        fn handler(comptime self: Self, comptime f: Self.F) Self {
            return Self{
                .name = self.name,
                .arguments = self.arguments,
                .options = self.options,
                .handler_fn = f,
            };
        }
    };
}

const cmd = Cmd("cli").option("--hello/-h", bool).argument("world", usize);

pub fn main() void {
    std.debug.print("{s}:\n", .{cmd.name});
    std.debug.print("handler type: {any}\n", .{@TypeOf(cmd).T});
    std.debug.print("options:\n", .{});
    for (cmd.options) |o| {
        std.debug.print("{s}, ", .{o});
    }
    std.debug.print("\n", .{});
    std.debug.print("arguments:\n", .{});
    for (cmd.arguments) |o| {
        std.debug.print("{s}, ", .{o});
    }
    std.debug.print("\n", .{});
}

const CmdParseState = enum {
    Init,
    OptionValue,
};

/// --option
/// value
/// --option2=value
/// --flag
/// argument
/// argument2
///
/// we need to keep track of:
/// - which argument we fill next (and if we've exhasted or not)
/// - whether an option has already been provided
/// -
///
fn parse(args_itr: std.process.Args.Interator) void {
    _ = args_itr;
    // var state: CmdParseState = .Init;
    // while (args_itr.next()) |token| switch (state) {
    //     .Init => {
    //         if (std.mem.startsWith(u8, token, @"-")) {
    //             state = .OptionValue;
    //             flag, value_str = _(token) orelse @panic("unrecognized or malformed option");
    //         } else {}
    //     },
    //     .OptionValue => {},
    // };
    // switch (state) {
    //     .Init => {},
    //     .OptionValue => {
    //         // we were expecting an option, but none found
    //     },
    // }
}
