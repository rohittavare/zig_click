//! util.zig
//!
//! helper functions, particularly instructions to manipulate comptime values which can be long
//! this helps us treat comptime values with similar level of convenience as runtime values which would require allocators
//! e.g. adding values to an array or map, mutate a value in a const array

const std = @import("std");

/// produces a new StaticStringMap using the contents of an existing StaticStringMap and adding a new KV pair
/// this function does not check for duplicate values being inserted. It assumes the existing map has only unique values
/// if an existing key is specified, the new value overwrites the old value
pub inline fn insertStaticStringMapComptime(comptime T: type, map: std.StaticStringMap(T), comptime new_entry: struct { []const u8, T }) std.StaticStringMap(T) {
    const kvs = map.kvs.*;
    comptime var entries: [kvs.len + 1]struct { []const u8, T } = undefined;
    inline for (kvs.keys, kvs.values, 0..kvs.len) |k, v, i| {
        entries[i + 1] = .{ k, v };
    }
    entries[0] = new_entry;
    return std.StaticStringMap(T).initComptime(entries);
}

test "merge_map" {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "hello", 2 },
        .{ "world", 3 },
    });
    const new_entry = .{ "entry", 7 };

    const result = insertStaticStringMapComptime(u8, map, new_entry);

    try std.testing.expectEqual(2, result.get("hello"));
    try std.testing.expectEqual(3, result.get("world"));
    try std.testing.expectEqual(7, result.get("entry"));
}

test "merge_map_duplicates" {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "hello", 2 },
        .{ "world", 3 },
    });
    const new_entry = .{ "world", 7 };

    const result = insertStaticStringMapComptime(u8, map, new_entry);
    try std.testing.expectEqual(2, result.get("hello"));
    try std.testing.expectEqual(7, result.get("world"));
}

/// produces a new tuple type by appending the given type as a new field to an existing tuple type
/// primarily used in `extendTupleComptime` and helpful for constructing the handler function signature type
/// as new option and argument types are added to a command
pub inline fn extendTupleType(comptime T: type, comptime appendT: type) type {
    return @Tuple(&(@typeInfo(T).@"struct".field_types.* ++ [1]type{appendT}));
}

pub inline fn prefixTupleType(comptime T: type, comptime prependT: type) type {
    return @Tuple(&([1]type{prependT} ++ @typeInfo(T).@"struct".field_types.*));
}

pub inline fn truncateTupleType(comptime T: type) type {
    return @Tuple(@typeInfo(T).@"struct".field_types[0 .. (@typeInfo(T).@"struct".field_types.len) - 1]);
}

test "extend_tuple_type" {
    const expected = struct { bool, usize, []const u8 };
    const actual = extendTupleType(struct { bool, usize }, []const u8);
    try std.testing.expectEqual(expected, actual);
}

test "prefix_tuple_type" {
    const expected = struct { bool, usize, []const u8 };
    const actual = prefixTupleType(struct { usize, []const u8 }, bool);
    try std.testing.expectEqual(expected, actual);
}

/// returns a new tuple which extends an existing tuple with a new field and optionally initializes the new field
/// values from existing tuple are copied over to the corresponding field in the new tuple
/// this is helpful to slowly construct a tuple of values (since an array cannot hold mixed types)
/// for the default value of each argument/option
pub fn extendTuple(comptime T: type, comptime appendT: type, tup: T, maybe_append: ?appendT) extendTupleType(T, appendT) {
    const N = @typeInfo(T).@"struct".field_names.len;
    const newT = extendTupleType(T, appendT);

    const next_field_ts = @typeInfo(newT).@"struct".field_types;
    const next_field_ns = @typeInfo(newT).@"struct".field_names;
    var ret: newT = undefined;
    inline for (@typeInfo(T).@"struct".field_names, next_field_ns[0..N], next_field_ts[0..N]) |old_field_n, new_field_n, new_field_t| {
        @field(ret, new_field_n) = @as(new_field_t, @field(tup, old_field_n));
    }
    if (maybe_append) |append| @field(ret, next_field_ns[N]) = @as(next_field_ts[N], append);
    return ret;
}

pub fn prefixTuple(comptime T: type, comptime prependT: type, tup: T, maybe_prepend: ?prependT) prefixTupleType(T, prependT) {
    const newT = prefixTupleType(T, prependT);

    const next_field_ts = @typeInfo(newT).@"struct".field_types;
    const next_field_ns = @typeInfo(newT).@"struct".field_names;
    var ret: newT = undefined;
    inline for (@typeInfo(T).@"struct".field_names, next_field_ns[1..], next_field_ts[1..]) |old_field_n, new_field_n, new_field_t| {
        @field(ret, new_field_n) = @as(new_field_t, @field(tup, old_field_n));
    }
    if (maybe_prepend) |prepend| @field(ret, next_field_ns[0]) = @as(next_field_ts[0], prepend);
    return ret;
}

pub fn truncateTuple(comptime T: type, tup: T) truncateTupleType(T) {
    const newT = truncateTupleType(T);

    const next_field_ts = @typeInfo(newT).@"struct".field_types;
    const next_field_ns = @typeInfo(newT).@"struct".field_names;
    var ret: newT = undefined;

    const old_field_ns = @typeInfo(T).@"struct".field_names;
    if (old_field_ns.len == 0) @compileError("cannot truncate tuple with no fields: " ++ @typeName(T));
    inline for (old_field_ns[0 .. old_field_ns.len - 1], next_field_ns, next_field_ts) |old_field_n, new_field_n, new_field_t| {
        @field(ret, new_field_n) = @as(new_field_t, @field(tup, old_field_n));
    }
    return ret;
}

test "extend_tuple_with_value" {
    const expected = .{ 34, true, "hello world" };
    const initial = .{ 34, true };
    try std.testing.expectEqual(expected, extendTuple(@TypeOf(initial), []const u8, initial, "hello world"));
}

test "extend_tuple_no_value" {
    const expected = struct { comptime_int, bool, []const u8 };
    const initial = .{ 34, true };
    try std.testing.expectEqual(expected, @TypeOf(extendTuple(@TypeOf(initial), []const u8, initial, null)));
}

test "prefix_tuple_with_value" {
    const expected = .{ 34, true, "hello world" };
    const initial = .{ true, "hello world" };
    try std.testing.expectEqual(expected, prefixTuple(@TypeOf(initial), comptime_int, initial, 34));
}

test "prefix_tuple_no_value" {
    const expected = struct { comptime_int, bool, []const u8 };
    const initial: struct { bool, []const u8 } = .{ true, "hello world" };
    try std.testing.expectEqual(expected, @TypeOf(prefixTuple(@TypeOf(initial), comptime_int, initial, null)));
}

/// produces a new slice which 'appends' the new value to the existing slice
pub inline fn extendSliceComptime(comptime T: type, comptime arr: []const T, comptime append: T) []const T {
    return &(arr.* ++ [1]T{append});
}

test "append_to_slice" {
    const expected: []const u8 = "hello world!";
    try std.testing.expectEqualSlices(u8, expected, extendSliceComptime(u8, "hello world", '!'));
}

/// produces a new array based on an existing array which sets the value of the array at a particular index
pub inline fn setArrComptime(comptime T: type, comptime N: usize, comptime arr: *const [N]T, comptime i: usize, comptime setVal: T) *const [N]T {
    return &(arr[0..i].* ++ [1]T{setVal} ++ arr[i + 1 ..].*);
}

test "set_array" {
    const expected = [_]u8{ 'h', 'e', 'l', 'l', 'o', '-', 'w', 'o', 'r', 'l', 'd', '.' };
    const initial = [_]u8{ 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '.' };
    try std.testing.expectEqualSlices(u8, &expected, setArrComptime(u8, 12, &initial, 5, '-'));
}

test "set_array_index_end" {
    const expected = [_]u8{ 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '!' };
    const initial = [_]u8{ 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '.' };
    try std.testing.expectEqualSlices(u8, &expected, setArrComptime(u8, 12, &initial, 11, '!'));
}

test "set_array_index_begin" {
    const expected = [_]u8{ 'y', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '.' };
    const initial = [_]u8{ 'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', '.' };
    try std.testing.expectEqualSlices(u8, &expected, setArrComptime(u8, 12, &initial, 0, 'y'));
}

/// a generic type to help us wrap and store values as opaque types
/// this allows us to store the mixed typing of parser arguments
/// without needing complex generics/type manipulation
pub fn Container(comptime t: type) type {
    return struct { inner: t };
}

pub inline fn toOpaquePtrComptime(comptime payload: anytype) *const anyopaque {
    return @ptrCast(&Container(@TypeOf(payload)){ .inner = payload });
}

pub fn toOpaquePtr(arena: *std.heap.ArenaAllocator, payload: anytype) !*const anyopaque {
    const container = try arena.allocator().create(Container(@TypeOf(payload)));
    container.* = .{ .inner = payload };
    return @ptrCast(container);
}

pub fn fromOpaquePtr(comptime t: type, ptr: ?*const anyopaque) t {
    return @as(*const Container(t), @ptrCast(@alignCast(ptr))).*.inner;
}

pub fn fromOpaquePtrMaybe(comptime t: type, maybe_ptr: ?*const anyopaque) ?t {
    return if (maybe_ptr) |ptr| fromOpaquePtr(t, ptr) else null;
}

fn add(a: usize, b: usize) usize {
    return a + b;
}
fn sub(a: usize, b: usize) usize {
    return a - b;
}

test "to_from_opaque_ptr_comptime" {
    try std.testing.expectEqual(@as(usize, 10), fromOpaquePtr(usize, toOpaquePtrComptime(@as(usize, 10))));
    try std.testing.expectEqual(@as(f16, 3.14), fromOpaquePtr(f16, toOpaquePtrComptime(@as(f16, 3.14))));
    try std.testing.expectEqualStrings("hello world!", fromOpaquePtr([]const u8, toOpaquePtrComptime(@as([]const u8, "hello world!"))));
    try std.testing.expectEqual(@as(?[]const u8, null), fromOpaquePtr(?[]const u8, toOpaquePtrComptime(@as(?[]const u8, null))));
    try std.testing.expectEqual(true, fromOpaquePtr(bool, toOpaquePtrComptime(true)));

    const add_ptr = toOpaquePtrComptime(&add);
    const sub_ptr = toOpaquePtrComptime(&sub);

    var fn_ptr = fromOpaquePtr(*const fn (usize, usize) usize, add_ptr);
    try std.testing.expectEqual(10, fn_ptr(5, 5));

    fn_ptr = fromOpaquePtr(*const fn (usize, usize) usize, sub_ptr);
    try std.testing.expectEqual(0, fn_ptr(5, 5));
}

test "to_from_opaque_ptr" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(usize, 10), fromOpaquePtr(usize, try toOpaquePtr(&arena, @as(usize, 10))));
    try std.testing.expectEqual(@as(f16, 3.14), fromOpaquePtr(f16, try toOpaquePtr(&arena, @as(f16, 3.14))));
    try std.testing.expectEqualStrings("hello world!", fromOpaquePtr([]const u8, try toOpaquePtr(&arena, @as([]const u8, "hello world!"))));
    try std.testing.expectEqual(@as(?[]const u8, null), fromOpaquePtr(?[]const u8, try toOpaquePtr(&arena, @as(?[]const u8, null))));
    try std.testing.expectEqual(true, fromOpaquePtr(bool, try toOpaquePtr(&arena, true)));

    const add_ptr = try toOpaquePtr(&arena, &add);
    const sub_ptr = try toOpaquePtr(&arena, &sub);

    var fn_ptr = fromOpaquePtr(*const fn (usize, usize) usize, add_ptr);
    try std.testing.expectEqual(10, fn_ptr(5, 5));

    fn_ptr = fromOpaquePtr(*const fn (usize, usize) usize, sub_ptr);
    try std.testing.expectEqual(0, fn_ptr(5, 5));
}
