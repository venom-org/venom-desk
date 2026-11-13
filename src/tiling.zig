//! Tiling policies. venomx keeps manual splits and one shared
//! layout per window (split ratios are shared); venom-desk's policies are
//! client code that decide *where* a new pane goes and express it as the
//! ordinary `pane.split` / `pane.place` verbs, so every client (including
//! `venomx attach`) shows the same arrangement.
const std = @import("std");

pub const Axis = enum { cols, rows };
/// flat preorder tree, as in venomx's snapshots.
pub const Node = struct {
    kind: enum { pane, split },
    pane: ?[]const u8 = null,
    axis: ?Axis = null,
    first: ?usize = null,
    second: ?usize = null,
};

pub fn valid(nodes: []const Node) bool {
    if (nodes.len == 0) return true;
    var next: usize = 0;
    if (!walkValid(nodes, 0, &next) or next != nodes.len) return false;
    for (nodes, 0..) |n, i| if (n.kind == .pane) {
        for (nodes[0..i]) |prev| if (prev.pane != null and std.mem.eql(u8, prev.pane.?, n.pane.?)) return false;
    };
    return true;
}
fn walkValid(nodes: []const Node, index: usize, next: *usize) bool {
    if (index != next.* or index >= nodes.len) return false;
    const n = nodes[index];
    next.* += 1;
    return switch (n.kind) {
        .pane => n.pane != null and n.axis == null and n.first == null and n.second == null,
        .split => n.pane == null and n.axis != null and n.first != null and n.second != null and walkValid(nodes, n.first.?, next) and walkValid(nodes, n.second.?, next),
    };
}

pub const Rect = @import("floats.zig").Rect;
pub const Leaf = struct { pane: []const u8, rect: Rect };

/// Leaf rectangles with venomx attach's geometry: equal shares, the first
/// child takes the extra cell, a one-cell separator. Borrowed pane IDs.
pub fn leaves(a: std.mem.Allocator, nodes: []const Node, area: Rect) ![]Leaf {
    var out: std.ArrayList(Leaf) = .empty;
    errdefer out.deinit(a);
    if (nodes.len > 0) try walk(a, &out, nodes, 0, area);
    return out.toOwnedSlice(a);
}
fn walk(a: std.mem.Allocator, out: *std.ArrayList(Leaf), nodes: []const Node, index: usize, r: Rect) !void {
    const n = nodes[index];
    if (n.kind == .pane) return out.append(a, .{ .pane = n.pane.?, .rect = r });
    const cols = n.axis.? == .cols;
    const total = if (cols) r.width else r.height;
    const avail = total -| 1;
    const first = avail - avail / 2;
    const sep = @min(total, 1);
    var one = r;
    var two = r;
    if (cols) {
        one.width = first;
        two.x = r.x +| first +| sep;
        two.width = avail / 2;
    } else {
        one.height = first;
        two.y = r.y +| first +| sep;
        two.height = avail / 2;
    }
    try walk(a, out, nodes, n.first.?, one);
    try walk(a, out, nodes, n.second.?, two);
}

pub const Policy = enum {
    /// Split the focused pane side by side, like `venomx attach`'s `%`.
    manual,
    /// Binary space partition: split the focused pane along its longer side.
    bsp,
    /// One master on the left, the rest stacked on the right.
    @"master-stack",
    /// New panes append a column to the right of the last pane.
    scrolling,
};

/// Where a new pane goes: `pane.split {pane, axis}` params (or the `tile`
/// member of `pane.place`).
pub const Split = struct { pane: []const u8, axis: Axis };

/// Decide the split for a new pane in a window. `focused` must be a leaf
/// of `nodes` (or null for no focus). `area` is this client's window area,
/// used only for the BSP aspect choice; the result is the same request on
/// any client size that has the same aspect class. Null for an empty window
/// (use `window.create` instead).
pub fn plan(a: std.mem.Allocator, policy: Policy, nodes: []const Node, focused: ?[]const u8, area: Rect) !?Split {
    const ls = try leaves(a, nodes, area);
    defer a.free(ls);
    if (ls.len == 0) return null;
    const target = blk: {
        if (focused) |f| for (ls) |l| if (std.mem.eql(u8, l.pane, f)) break :blk l;
        break :blk ls[ls.len - 1];
    };
    return switch (policy) {
        .manual => .{ .pane = target.pane, .axis = .cols },
        // Terminal cells are about twice as tall as wide.
        .bsp => .{ .pane = target.pane, .axis = if (target.rect.width >= target.rect.height * 2) .cols else .rows },
        .@"master-stack" => if (ls.len == 1)
            .{ .pane = ls[0].pane, .axis = .cols }
        else
            .{ .pane = ls[ls.len - 1].pane, .axis = .rows },
        .scrolling => .{ .pane = ls[ls.len - 1].pane, .axis = .cols },
    };
}

const test_nodes = [_]Node{
    .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
    .{ .kind = .pane, .pane = "p0" },
    .{ .kind = .split, .axis = .rows, .first = 3, .second = 4 },
    .{ .kind = .pane, .pane = "p1" },
    .{ .kind = .pane, .pane = "p2" },
};

test "leaf geometry matches venomx attach" {
    const a = std.testing.allocator;
    const ls = try leaves(a, &test_nodes, .{ .y = 1, .width = 81, .height = 23 });
    defer a.free(ls);
    try std.testing.expectEqual(@as(usize, 3), ls.len);
    try std.testing.expectEqual(Rect{ .y = 1, .width = 40, .height = 23 }, ls[0].rect);
    try std.testing.expectEqual(Rect{ .x = 41, .y = 1, .width = 40, .height = 11 }, ls[1].rect);
    try std.testing.expectEqual(Rect{ .x = 41, .y = 13, .width = 40, .height = 11 }, ls[2].rect);
    try std.testing.expect(valid(&test_nodes));
    try std.testing.expect(!valid(test_nodes[1..]));
}

test "policies choose the split" {
    const a = std.testing.allocator;
    const area: Rect = .{ .width = 160, .height = 41 };
    try std.testing.expectEqual(Split{ .pane = "p0", .axis = .cols }, (try plan(a, .manual, &test_nodes, "p0", area)).?);
    // p0 is 80x41: taller than wide in cell aspect → rows.
    try std.testing.expectEqual(Axis.rows, (try plan(a, .bsp, &test_nodes, "p0", area)).?.axis);
    const single = [_]Node{.{ .kind = .pane, .pane = "p0" }};
    try std.testing.expectEqual(Axis.cols, (try plan(a, .bsp, &single, "p0", area)).?.axis);
    try std.testing.expectEqual(Split{ .pane = "p0", .axis = .cols }, (try plan(a, .@"master-stack", &single, null, area)).?);
    try std.testing.expectEqual(Split{ .pane = "p2", .axis = .rows }, (try plan(a, .@"master-stack", &test_nodes, "p0", area)).?);
    try std.testing.expectEqual(Split{ .pane = "p2", .axis = .cols }, (try plan(a, .scrolling, &test_nodes, "p1", area)).?);
    try std.testing.expect((try plan(a, .bsp, &.{}, null, area)) == null);
}
