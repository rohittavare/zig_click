//! types.zig
//!
//! basic checks for supported types
//! only supporting int, float, bool and string types (as `[]const u8`) for now
//! in the future we may be able to support arbitrary types if we can implement
//! opt/arg callbacks which can accept a string and transform it to the desired type

const std = @import("std");

/// currently only supporting ints, floats, and strings as valid option types when parsing
/// booleans are omitted as they should be implemented using flags
pub inline fn is_supported_option_type(comptime t: type) bool {
    return switch (@typeInfo(t)) {
        .int, .float => true,
        .optional => |o| is_supported_option_type(o.child),
        .pointer => |p| (p.size == .slice and p.attrs.@"const" and p.child == u8),
        else => false,
    };
}

/// currently only supporting ints, floats, booleans and strings as valid argument types when parsing
/// in the future it may be possible to support arbitrary slices or arrays using variadic arguments
pub inline fn is_supported_argument_type(comptime t: type) bool {
    return switch (@typeInfo(t)) {
        .int, .float, .bool => true,
        .optional => |o| is_supported_argument_type(o.child),
        .pointer => |p| (p.size == .slice and p.attrs.@"const" and p.child == u8),
        else => false,
    };
}

const checkers = .{ is_supported_option_type, is_supported_argument_type };
test "string_slices_supported" {
    inline for (@typeInfo(@TypeOf(checkers)).@"struct".field_names) |f| {
        const c = @field(checkers, f);
        try std.testing.expect(c([]const u8));
        // literal string types not supported
        try std.testing.expect(!c(@TypeOf("hello world!")));
        // non-const not supported
        try std.testing.expect(!c([]u8));
        // other integer types not supported
        try std.testing.expect(!c([]const u16));
    }
}

test "optional_types_supported" {
    inline for (@typeInfo(@TypeOf(checkers)).@"struct".field_names) |f| {
        const c = @field(checkers, f);
        try std.testing.expect(c(?f32));
        try std.testing.expect(c(?i16));
        try std.testing.expect(c(?[]const u8));

        // example unsupported type
        try std.testing.expect(!c(?[]u8));
    }
}

/// rather than expose raw types in CLI outputs
/// convert types to a human-friendly name
/// unwrap optinoals to expose the underlying type
pub inline fn type_to_name(comptime t: type) []const u8 {
    if (t == usize) return "SIZE";
    return switch (@typeInfo(t)) {
        .int => "INT",
        .float => "FLOAT",
        .bool => "BOOL",
        .optional => |o| type_to_name(o.child),
        .pointer => |p| if (p.size == .slice and p.attrs.@"const" and p.child == u8) "TEXT",
        else => unreachable,
    };
}

test "type_to_name_conversion" {
    try std.testing.expectEqualStrings("FLOAT", type_to_name(f16));
    try std.testing.expectEqualStrings("BOOL", type_to_name(bool));
    try std.testing.expectEqualStrings("TEXT", type_to_name([]const u8));
    // special SIZE type
    try std.testing.expectEqualStrings("SIZE", type_to_name(usize));
    // handles both signed & unsigned ints
    try std.testing.expectEqualStrings("INT", type_to_name(u16));
    try std.testing.expectEqualStrings("INT", type_to_name(i16));
    // unwrap optionals
    try std.testing.expectEqualStrings("TEXT", type_to_name(?[]const u8));
}
