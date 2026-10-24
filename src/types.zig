//! types.zig
//!
//! basic checks for supported types
//! only supporting int, float, bool and string types (as `[]const u8`) for now
//! in the future we may be able to support arbitrary types if we can implement
//! opt/arg callbacks which can accept a string and transform it to the desired type

const std = @import("std");

pub const Type = enum {
    BOOL,
    // ----- string types -----
    /// alias: `[]const u8`
    TEXT,
    /// alias: `[]const u8`
    STRING,
    /// alias: `[]const u8`
    LINE,
    /// alias: `[]const u8`
    ///
    /// reserved for internal use
    COMMAND,
    // ----- number types -----
    /// alias: `usize`
    SIZE,
    /// alias: `usize`
    COUNT,
    /// alias: `usize`
    LENGTH,
    /// alias: `i8`
    I8,
    /// alias: `i16`
    I16,
    /// alias: `i32`
    I32,
    /// alias: `i64`
    I64,
    /// alias: `u8`
    U8,
    /// alias: `u16`
    U16,
    /// alias: `u32`
    U32,
    /// alias: `u64`
    U64,
    /// alias: `f16`
    F16,
    /// alias: `f32`
    F32,
    /// alias: `f64`
    F64,

    pub inline fn toType(comptime self: Type) type {
        return switch (self) {
            .BOOL => bool,
            .TEXT, .STRING, .LINE, .COMMAND => []const u8,
            .SIZE, .COUNT, .LENGTH => usize,
            .I8 => i8,
            .I16 => i16,
            .I32 => i32,
            .I64 => i64,
            .U8 => u8,
            .U16 => u16,
            .U32 => u32,
            .U64 => u64,
            .F16 => f16,
            .F32 => f32,
            .F64 => f64,
        };
    }
};

pub inline fn hintedType(comptime t: type, comptime hint: []const u8) HintedType {
    comptime {
        for (hint) |c| switch (c) {
            'A'...'Z', '_' => {},
            else => @compileError("type hint can only consist of underscore (`_`) and upper case letters"),
        };
        return .{
            .t = t,
            .hint = hint,
        };
    }
}

pub const HintedType = struct {
    t: type,
    hint: []const u8,
};

pub const CliType = union(enum) {
    type_enum: Type,
    hinted_type: HintedType,
    raw_type: type,

    pub inline fn init(comptime t: anytype) CliType {
        return switch (@TypeOf(t)) {
            Type => .{ .type_enum = t },
            HintedType => .{ .hinted_type = t },
            type => .{ .raw_type = t },
            else => |e| @compileError("command line types must be expressed as one of { `Type` | `HintedType` | `type` }; instead found: " ++ @typeName(e)),
        };
    }

    pub inline fn asRawType(comptime self: CliType) type {
        return switch (self) {
            .type_enum => |e| e.toType(),
            .raw_type => |t| t,
            .hinted_type => |h| h.t,
        };
    }

    /// rather than expose raw types in CLI outputs
    /// convert types to a human-friendly name
    /// unwrap optinoals to expose the underlying type
    pub inline fn hint(comptime self: CliType) []const u8 {
        return switch (self) {
            .type_enum => |e| switch (e) {
                .I8, .I16, .I32, .I64 => "INT",
                .U8, .U16, .U32, .U64 => "INT",
                .F16, .F32, .F64 => "FLOAT",
                else => @tagName(e),
            },
            .hinted_type => |h| h.hint,
            .raw_type => |r| type_name: {
                if (r == usize) break :type_name "SIZE";
                break :type_name switch (@typeInfo(r)) {
                    .int => "INT",
                    .float => "FLOAT",
                    .bool => "BOOL",
                    .optional => |o| CliType.init(o.child).hint(),
                    .pointer => |p| if (p.size == .slice and p.attrs.@"const" and p.child == u8) "TEXT",
                    .@"enum" => comptime enum_name: {
                        const full_name = @typeName(r);
                        const dot_idx = std.mem.findLast(u8, full_name, ".") orelse break :enum_name full_name;
                        break :enum_name full_name[dot_idx + 1 ..];
                    },
                    else => "TEXT",
                };
            },
        };
    }

    /// parse a token to the desired data type
    /// only int, float, bool and string types supported natively
    /// otherwise a custom handler is required to parse the data type
    /// does not parse null values for optional types
    /// returns null when the datatype is unsupported or failure during parsing
    pub fn parseToken(comptime self: CliType, token: []const u8) ?self.asRawType() {
        return switch (self) {
            .type_enum => |e| switch (e) {
                else => CliType.init(e.toType()).parseToken(token),
            },
            .hinted_type => |h| CliType.init(h.t).parseToken(token),
            .raw_type => |r| switch (@typeInfo(r)) {
                .optional => |o| CliType.init(o.child).parseToken(token) orelse null,
                .int => std.fmt.parseInt(r, token, 10) catch null,
                .float => std.fmt.parseFloat(r, token) catch null,
                .bool => if (std.mem.eql(u8, token, "true")) true else if (std.mem.eql(u8, token, "false")) false else null,
                // currently only support strings through slice of const u8
                .pointer => |p| if (p.size == .slice and p.attrs.@"const" and p.child == u8) token else null,
                .@"enum" => std.meta.stringToEnum(r, token),
                else => null,
            },
        };
    }
};

/// currently only supporting ints, floats, and strings as valid option types when parsing
/// booleans are omitted as they should be implemented using flags
pub inline fn is_supported_native_option_type(comptime t: CliType) bool {
    return switch (t) {
        .type_enum => |e| switch (e) {
            .BOOL => false,
            else => true,
        },
        .hinted_type => |h| is_supported_native_option_type(.init(h.t)),
        .raw_type => |r| switch (@typeInfo(r)) {
            .int, .float, .@"enum" => true,
            .pointer => |p| (p.size == .slice and p.attrs.@"const" and p.child == u8),
            else => false,
        },
    };
}

/// currently only supporting ints, floats, booleans and strings as valid argument types when parsing
/// slices, arrays and other types need to be suppored via a custom handler
pub inline fn is_supported_native_argument_type(comptime t: CliType) bool {
    return switch (t) {
        .type_enum => true,
        .hinted_type => |h| is_supported_native_option_type(.init(h)),
        .raw_type => |r| switch (@typeInfo(r)) {
            .int, .float, .bool, .@"enum" => true,
            .pointer => |p| (p.size == .slice and p.attrs.@"const" and p.child == u8),
            else => false,
        },
    };
}

const checkers = .{ is_supported_native_option_type, is_supported_native_argument_type };
test "string_slices_supported" {
    inline for (checkers) |c| {
        try std.testing.expect(c(.init([]const u8)));
        // literal string types not supported
        try std.testing.expect(!c(.init(@TypeOf("hello world!"))));
        // non-const not supported
        try std.testing.expect(!c(.init([]u8)));
        // other integer types not supported
        try std.testing.expect(!c(.init([]const u16)));
    }
}

test "hinted_types_supported" {
    inline for (checkers) |c| {
        try std.testing.expect(c(.init(hintedType([]const u8, "FILE_NAME"))));
        try std.testing.expect(c(.init(hintedType(usize, "WIDTH"))));
        try std.testing.expect(!c(.init(hintedType([]const []const u8, "LINES"))));
    }
}

const testEnum = enum {
    foo,
    bar,
};

test "type_to_name_conversion" {
    const cases = .{
        .{ "FLOAT", f16 },
        .{ "BOOL", bool },
        .{ "TEXT", []const u8 },
        // special SIZE type
        .{ "SIZE", usize },
        // handles both signed & unsigned ints
        .{ "INT", u16 },
        .{ "INT", i16 },
        // unwrap optionals
        .{ "TEXT", ?[]const u8 },
        // enum
        .{ "testEnum", testEnum },
        // `Type` enum
        .{ "STRING", Type.STRING },
        .{ "INT", Type.I32 },
        .{ "INT", Type.U8 },
        .{ "FLOAT", Type.F64 },
        // hinted types
        .{ "FILE", hintedType([]const u8, "FILE") },
        .{ "FOOBAR", hintedType(testEnum, "FOOBAR") },
    };
    inline for (cases) |case| {
        const expected, const t = case;
        try std.testing.expectEqualStrings(expected, CliType.init(t).hint());
    }
}
