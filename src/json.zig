//! Small readers for `std.json.Value` trees from the daemon. A missing or
//! mistyped member reads as null; callers decide whether that is an error.
const std = @import("std");
const Value = std.json.Value;

pub fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
pub fn str(v: Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
pub fn int(v: Value, key: []const u8) ?i64 {
    const f = get(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}
pub fn boolean(v: Value, key: []const u8) ?bool {
    const f = get(v, key) orelse return null;
    return if (f == .bool) f.bool else null;
}
pub fn array(v: Value, key: []const u8) ?[]Value {
    const f = get(v, key) orelse return null;
    return if (f == .array) f.array.items else null;
}
