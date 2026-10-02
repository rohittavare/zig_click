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
    switch (@typeInfo(t)) {
        .int, .float => return true,
        .optional => |o| return is_supported_option_type(o.child),
        .pointer => |p| return (p.size == .slice and p.attrs.@"const" and p.child == u8),
        else => return false,
    }
}

/// currently only supporting ints, floats, booleans and strings as valid argument types when parsing
/// in the future it may be possible to support arbitrary slices or arrays using variadic arguments
pub inline fn is_supported_argument_type(comptime t: type) bool {
    switch (@typeInfo(t)) {
        .int, .float, .bool => return true,
        .optional => |o| return is_supported_argument_type(o.child),
        .pointer => |p| return (p.size == .slice and p.attrs.@"const" and p.child == u8),
        else => return false,
    }
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
