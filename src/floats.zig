//! Floating panes and popups: geometry specs, presets with
//! fallback, and resolution against this client's own window area. The spec
//! and z-order are shared; the resolved rectangle and whether the float
//! layer is visible belong to this client.
const std = @import("std");
const json = @import("json.zig");
const Value = std.json.Value;

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
};

/// Cells (`80`) or a percent of the window area (`"60%"`).
pub const Size = union(enum) {
    cells: u16,
    percent: u8,

    pub fn resolve(self: Size, total: u16) u16 {
        return switch (self) {
            .cells => |c| c,
            .percent => |p| @intCast((@as(u32, total) * p) / 100),
        };
    }
    pub fn fromValue(v: Value) !Size {
        switch (v) {
            .integer => |i| {
                if (i < 1 or i > std.math.maxInt(u16)) return error.InvalidGeometry;
                return .{ .cells = @intCast(i) };
            },
            .string => |s| {
                if (s.len < 2 or s[s.len - 1] != '%') {
                    const n = std.fmt.parseInt(u16, s, 10) catch return error.InvalidGeometry;
                    if (n == 0) return error.InvalidGeometry;
                    return .{ .cells = n };
                }
                const p = std.fmt.parseInt(u8, s[0 .. s.len - 1], 10) catch return error.InvalidGeometry;
                if (p == 0 or p > 100) return error.InvalidGeometry;
                return .{ .percent = p };
            },
            else => return error.InvalidGeometry,
        }
    }
};

pub const Anchor = enum { center, top, bottom, left, right, @"top-left", @"top-right", @"bottom-left", @"bottom-right" };
pub const Border = enum { none, single, rounded, heavy };

/// A complete spec (`floats.default` and resolved presets).
pub const Spec = struct {
    width: Size = .{ .percent = 60 },
    height: Size = .{ .percent = 60 },
    anchor: Anchor = .center,
    x: i32 = 0,
    y: i32 = 0,
    min_cols: u16 = 20,
    min_rows: u16 = 5,
    border: Border = .rounded,
    /// Borrowed; empty means use the pane's OSC 2 title.
    title: []const u8 = "",
};

/// A preset or explicit geometry params: every field optional, applied
/// field by field over a base: explicit geometry params override the
/// preset field by field.
pub const Partial = struct {
    width: ?Size = null,
    height: ?Size = null,
    anchor: ?Anchor = null,
    x: ?i32 = null,
    y: ?i32 = null,
    min_cols: ?u16 = null,
    min_rows: ?u16 = null,
    border: ?Border = null,
    title: ?[]const u8 = null,

    pub fn over(self: Partial, base: Spec) Spec {
        var out = base;
        inline for (comptime std.meta.fieldNames(Partial)) |name| {
            if (@field(self, name)) |v| @field(out, name) = v;
        }
        return out;
    }
    /// Reads geometry members of a JSON object; unknown members are ignored
    /// so a whole `pane.float` params object or snapshot entity can be passed.
    /// Strings borrow from `v`.
    pub fn fromValue(v: Value) !Partial {
        var p: Partial = .{};
        if (json.get(v, "width")) |w| p.width = try Size.fromValue(w);
        if (json.get(v, "height")) |h| p.height = try Size.fromValue(h);
        if (json.str(v, "anchor")) |s| {
            // venomx spells corners `top_left`; venom-desk `top-left`.
            var buf: [16]u8 = undefined;
            if (s.len > buf.len) return error.InvalidGeometry;
            for (s, 0..) |ch, i| buf[i] = if (ch == '_') '-' else ch;
            p.anchor = std.meta.stringToEnum(Anchor, buf[0..s.len]) orelse return error.InvalidGeometry;
        }
        if (json.int(v, "x")) |i| p.x = std.math.cast(i32, i) orelse return error.InvalidGeometry;
        if (json.int(v, "y")) |i| p.y = std.math.cast(i32, i) orelse return error.InvalidGeometry;
        if (json.int(v, "min_cols")) |i| p.min_cols = std.math.cast(u16, i) orelse return error.InvalidGeometry;
        if (json.int(v, "min_rows")) |i| p.min_rows = std.math.cast(u16, i) orelse return error.InvalidGeometry;
        if (json.str(v, "border")) |s| p.border = std.meta.stringToEnum(Border, s) orelse return error.InvalidGeometry;
        if (json.str(v, "title")) |s| {
            if (s.len > 128) return error.InvalidGeometry;
            p.title = s;
        }
        return p;
    }
};

pub const Placement = struct {
    rect: Rect,
    /// The area was below `min_cols`/`min_rows`, so the float fills it.
    full_window: bool,
};

/// Resolve a spec against this client's window area: size, clamp to
/// the area, anchor, offset, clamp again so the float stays on screen.
pub fn resolve(spec: Spec, area: Rect) Placement {
    if (area.width < spec.min_cols or area.height < spec.min_rows) return .{ .rect = area, .full_window = true };
    var w = @min(spec.width.resolve(area.width), area.width);
    var h = @min(spec.height.resolve(area.height), area.height);
    w = @max(w, @min(spec.min_cols, area.width));
    h = @max(h, @min(spec.min_rows, area.height));
    const free_w: i32 = @as(i32, area.width) - w;
    const free_h: i32 = @as(i32, area.height) - h;
    const col: i32 = switch (spec.anchor) {
        .left, .@"top-left", .@"bottom-left" => 0,
        .right, .@"top-right", .@"bottom-right" => free_w,
        .center, .top, .bottom => @divTrunc(free_w, 2),
    };
    const row: i32 = switch (spec.anchor) {
        .top, .@"top-left", .@"top-right" => 0,
        .bottom, .@"bottom-left", .@"bottom-right" => free_h,
        .center, .left, .right => @divTrunc(free_h, 2),
    };
    const x = std.math.clamp(col + spec.x, 0, free_w);
    const y = std.math.clamp(row + spec.y, 0, free_h);
    return .{ .rect = .{ .x = area.x + @as(u16, @intCast(x)), .y = area.y + @as(u16, @intCast(y)), .width = w, .height = h }, .full_window = false };
}

/// `floats.default` plus named presets. Products register defaults
/// (`floats.register`, product layer); user config wins.
pub const Presets = struct {
    pub const Layer = enum(u8) { product = 0, defaults = 1, user = 2 };
    const Entry = struct { name: []u8, layer: Layer, partial: Partial, title: ?[]u8 };

    a: std.mem.Allocator,
    default: Spec = .{},
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(a: std.mem.Allocator) Presets {
        return .{ .a = a };
    }
    pub fn deinit(self: *Presets) void {
        for (self.entries.items) |e| self.free(e);
        self.entries.deinit(self.a);
    }
    fn free(self: *Presets, e: Entry) void {
        self.a.free(e.name);
        if (e.title) |t| self.a.free(t);
    }
    /// Set a preset at `layer`, replacing the same name at the same layer.
    pub fn put(self: *Presets, name: []const u8, layer: Layer, partial: Partial) !void {
        const owned_name = try self.a.dupe(u8, name);
        errdefer self.a.free(owned_name);
        const title = if (partial.title) |t| try self.a.dupe(u8, t) else null;
        errdefer if (title) |t| self.a.free(t);
        var p = partial;
        p.title = title;
        for (self.entries.items) |*e| if (e.layer == layer and std.mem.eql(u8, e.name, name)) {
            self.free(e.*);
            e.* = .{ .name = owned_name, .layer = layer, .partial = p, .title = title };
            return;
        };
        try self.entries.append(self.a, .{ .name = owned_name, .layer = layer, .partial = p, .title = title });
    }
    /// Drop every preset of one layer (a config reload replaces `user`).
    pub fn clearLayer(self: *Presets, layer: Layer) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].layer == layer) {
                self.free(self.entries.orderedRemove(i));
            } else i += 1;
        }
    }
    pub const Lookup = struct { spec: Spec, known: bool };
    /// The preset over `floats.default`, lower layers first so higher ones
    /// win per field. An unknown name falls back to the default, and
    /// `known = false` lets `doctor` report it; it is never an error.
    pub fn lookup(self: *const Presets, name: ?[]const u8) Lookup {
        var spec = self.default;
        const n = name orelse return .{ .spec = spec, .known = true };
        var known = false;
        inline for (.{ Layer.product, Layer.defaults, Layer.user }) |layer| {
            for (self.entries.items) |e| if (e.layer == layer and std.mem.eql(u8, e.name, n)) {
                spec = e.partial.over(spec);
                known = true;
            };
        }
        return .{ .spec = spec, .known = known };
    }
};

test "percent and cell sizes resolve against each client's area" {
    const spec: Spec = .{ .width = .{ .percent = 60 }, .height = .{ .percent = 60 } };
    const big = resolve(spec, .{ .width = 100, .height = 40 });
    try std.testing.expectEqual(Rect{ .x = 20, .y = 8, .width = 60, .height = 24 }, big.rect);
    const small = resolve(spec, .{ .width = 80, .height = 24 });
    try std.testing.expectEqual(Rect{ .x = 16, .y = 5, .width = 48, .height = 14 }, small.rect);
    // Below the minimums the float takes the whole area.
    const tiny = resolve(spec, .{ .y = 1, .width = 15, .height = 10 });
    try std.testing.expect(tiny.full_window);
    try std.testing.expectEqual(Rect{ .y = 1, .width = 15, .height = 10 }, tiny.rect);
}

test "anchors and offsets stay inside the area" {
    const launcher: Spec = .{ .width = .{ .percent = 50 }, .height = .{ .percent = 40 }, .anchor = .top, .y = 2 };
    const r = resolve(launcher, .{ .y = 1, .width = 80, .height = 23 }).rect;
    try std.testing.expectEqual(Rect{ .x = 20, .y = 3, .width = 40, .height = 9 }, r);
    const diff: Spec = .{ .width = .{ .percent = 100 }, .height = .{ .percent = 70 }, .anchor = .bottom };
    try std.testing.expectEqual(Rect{ .x = 0, .y = 8, .width = 80, .height = 16 }, resolve(diff, .{ .y = 1, .width = 80, .height = 23 }).rect);
    const off: Spec = .{ .width = .{ .cells = 30 }, .height = .{ .cells = 10 }, .anchor = .@"bottom-right", .x = 50, .y = 50 };
    try std.testing.expectEqual(Rect{ .x = 50, .y = 14, .width = 30, .height = 10 }, resolve(off, .{ .width = 80, .height = 24 }).rect);
}

test "presets layer per field, unknown names fall back" {
    var presets = Presets.init(std.testing.allocator);
    defer presets.deinit();
    try presets.put("venom.settings", .product, .{ .width = .{ .percent = 80 }, .height = .{ .percent = 80 }, .title = "venom settings" });
    try presets.put("venom.settings", .user, .{ .width = .{ .percent = 90 } });
    const got = presets.lookup("venom.settings");
    try std.testing.expect(got.known);
    try std.testing.expectEqual(Size{ .percent = 90 }, got.spec.width);
    try std.testing.expectEqual(Size{ .percent = 80 }, got.spec.height);
    try std.testing.expectEqualStrings("venom settings", got.spec.title);
    const missing = presets.lookup("venom.nope");
    try std.testing.expect(!missing.known);
    try std.testing.expectEqual(Size{ .percent = 60 }, missing.spec.width);
    presets.clearLayer(.user);
    try std.testing.expectEqual(Size{ .percent = 80 }, presets.lookup("venom.settings").spec.width);
}

test "geometry params parse cells and percent" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"width\":\"80%\",\"height\":12,\"anchor\":\"top-right\",\"x\":-2,\"title\":\"diff\",\"argv\":[\"x\"]}", .{});
    defer parsed.deinit();
    const p = try Partial.fromValue(parsed.value);
    try std.testing.expectEqual(Size{ .percent = 80 }, p.width.?);
    try std.testing.expectEqual(Size{ .cells = 12 }, p.height.?);
    try std.testing.expectEqual(Anchor.@"top-right", p.anchor.?);
    try std.testing.expectEqual(@as(i32, -2), p.x.?);
    var bad = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"width\":\"0%\"}", .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidGeometry, Partial.fromValue(bad.value));
}
