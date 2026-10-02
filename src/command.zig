//! Implementation of an executable command that support option & argument specification

const std = @import("std");
const parser = @import("parser.zig");
const util = @import("util.zig");
const types = @import("types.zig");

const EmptyCommandType = CommandStruct(struct {});
pub fn Command(comptime name: []const u8, comptime description: []const u8) EmptyCommandType {
    return EmptyCommandType{ .name = name, .description = description, .defaults = .{} };
}

const ParseState = union(enum) {
    Neutral: void,
    OptionValue: usize,
};

const FlagInfo = struct {
    bool_value: ?bool,
    tuple_pos: usize,
};

fn CommandStruct(comptime t: type) type {
    return struct {
        name: []const u8,
        description: []const u8,
        defaults: T,
        long_flags: std.StaticStringMap(FlagInfo),
        short_flags: [52]?FlagInfo = @splat(null),
        arguments: []const usize = &[0]usize{},
        handler_fn: ?HandlerT = null,

        const Self = @This();
        const T = t;
        const HandlerT = @Fn(@typeInfo(T).@"struct".field_types, &@as([N]std.builtin.Type.Fn.ParamAttributes, @splat(std.builtin.Type.Fn.ParamAttributes{})), error{}!void, std.builtin.Type.Fn.Attributes{});
        const N = @typeInfo(t).@"struct".field_names.len;

        pub inline fn option(comptime self: Self, comptime flags: []const u8, comptime opT: type) CommandStruct(util.extendTupleType(T, ?opT)) {
            return self.optionWithDefault(flags, ?opT, null);
        }

        inline fn extendWithType(comptime self: Self, comptime appendT: type, comptime default: ?appendT) util.extendTupleType(T, appendT) {
            return CommandStruct(util.extendTupleType(T, appendT)){ .name = self.name, .description = self.description, .defaults = util.extendTupleComptime(T, appendT, self.defaults, default), .long_flags = self.long_flags, .short_flags = self.short_flags, .arguments = self.arguments, .handler_fn = self.handler_fn };
        }

        pub inline fn optionWithDefault(comptime self: Self, comptime flags: []const u8, comptime opT: type, comptime default: opT) util.extendTupleType(T, opT) {
            comptime {
                if (!types.is_supported_option_type(opT)) @compileError("unsupported option type");
                const flag_info = FlagInfo{ .bool_value = null, .tuple_pos = N };
                var ret = self.extendWithType(opT, default);
                const parsed_flags = parser.parseOptionComptime(flags);
                if (parsed_flags.long) |long| {
                    ret.long_flags = util.mergeMapComptime(FlagInfo, self.long_flags, .{ long, flag_info });
                }
                if (parsed_flags.short) |short| switch (short) {
                    'a'...'z' => ret.short_flags[@intCast(short)] = flag_info,
                    'A'...'Z' => ret.short_flags[@intCast(short - 'A' + 26)] = flag_info,
                    else => unreachable,
                };
                return ret;
            }
        }

        pub inline fn flag(comptime self: Self, comptime flag_n: []const u8) CommandStruct(util.extendTupleType(T, bool)) {
            comptime {
                var ret = self.extendWithType(bool, false);
                const flag_info = parser.parseBoolFlagComptime(flag_n);
                if (flag_info.long_positive) |flag_token| ret.long_flags = util.mergeMapComptime(usize, ret.long_flags, .{ flag_token, FlagInfo{ .bool_value = true, .tuple_pos = N } });
                if (flag_info.long_negative) |flag_token| ret.long_flags = util.mergeMapComptime(usize, ret.long_flags, .{ flag_token, FlagInfo{ .bool_value = false, .tuple_pos = N } });
                if (flag_info.short_positive) |flag_char| ret.short_flags = util.setArrComptime(FlagInfo, 52, ret.short_flags, flag_char, FlagInfo{ .bool_value = true, .tuple_pos = N });
                if (flag_info.short_negative) |flag_char| ret.short_flags = util.setArrComptime(FlagInfo, 52, ret.short_flags, flag_char, FlagInfo{ .bool_value = false, .tuple_pos = N });
                return ret;
            }
        }

        pub inline fn argument(comptime self: Self, comptime argT: type) CommandStruct(util.extendTupleType(T, argT)) {
            comptime {
                if (!types.is_supported_argument_type(argT)) @compileError("unsupported argument type");
                var ret = self.extendWithType(argT, null);
                ret.arguments = util.extendSliceComptime(usize, self.arguments, N);
                return ret;
            }
        }

        pub inline fn handler(comptime self: Self, comptime handler_fn: HandlerT) Self {
            if (self.handler_fn) |_| @compileError("handler function is already registered");
            return Self{
                .name = self.name,
                .description = self.description,
                .handler_fn = handler_fn,
            };
        }

        fn parseInput(comptime self: Self, input: *std.process.Args.Iterator) !T {
            const tokens: [N]?[]const u8 = @splat(null);
            var parse_state: ParseState = .Neutral;
            var arg_pos: usize = 0;
            while (input.next()) |token| switch (parse_state) {
                .Neutral => {
                    if (std.mem.startsWith(u8, token, "--")) {
                        // long option/flag names
                        const flagname, const maybe_value = if (std.mem.findScalar(u8, token, '=')) |delimiter_pos| .{ token[0..delimiter_pos], .token[delimiter_pos + 1 ..] } else .{ token, null };
                        if (std.mem.eql(u8, flagname, "--help")) {
                            // help flag
                        } else if (self.long_flags.get(flagname)) |flag_info| {
                            if (flag_info.bool_value) |bool_val| {
                                tokens[flag_info.tuple_pos] = if (bool_val) "true" else "false";
                            } else if (maybe_value) |value| {
                                tokens[flag_info.tuple_pos] = value;
                            } else {
                                parse_state = .{ .OptionValue = flag_info.tuple_pos };
                            }
                        } else {
                            @panic("unrecognized flag");
                        }
                    } else if (std.mem.startsWith(u8, tokens, "-")) {
                        // short option/flag names; can contain multiple flags & flag value in one token
                        for (token, 0..) |char, i| {
                            const maybe_flag_info = get_flag_info: switch (char) {
                                'a'...'z' => break :get_flag_info self.short_flags[@intCast(char - 'a')],
                                'A'...'Z' => break :get_flag_info self.short_flags[@intCast(char - 'A' + 26)],
                                else => {
                                    // error
                                    @panic("improper short flag formatting");
                                },
                            };
                            if (maybe_flag_info) |flag_info| {
                                if (flag_info.bool_value) |bool_val| {
                                    tokens[flag_info.tuple_pos] = if (bool_val) "true" else "false";
                                } else if (i == token.len - 1) {
                                    parse_state = .{ .OptionValue = flag_info.tuple_pos };
                                } else {
                                    tokens[flag_info.tuple_pos] = token[i + 1 ..];
                                    break;
                                }
                            } else {
                                @panic("unrecognized flag");
                            }
                        }
                    } else if (arg_pos < self.arguments.len) {
                        // argument
                        tokens[self.arguments[arg_pos]] = token;
                        arg_pos += 1;
                    } else {
                        @panic("unexpected argument");
                    }
                },
                .OptionValue => |o| {
                    // option values, ingest the whole token as the option in position `o'
                    tokens[o] = token;
                    parse_state = .{ .Neutral = void };
                },
            };

            var inputs: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, tokens) |f_n, f_t, maybe_token| {
                @field(inputs, f_n) = if (maybe_token) |token| parser.parseToken(f_t, token) else @field(self.defaults, f_n);
            }
            return inputs;
        }
    };
}
