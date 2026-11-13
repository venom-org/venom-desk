//! venom-desk's copy of the venomx daemon's shared state: topology, pane tags, attention, status segments, the
//! notification queue, and the float layer. It is fed the same
//! event items that `venomx attach` consumes, so both clients render the
//! same content. Nothing here is per-client; that lives in `view.zig`.
const std = @import("std");
const json = @import("json.zig");
const cs = @import("term_chrome").status;
const Tags = @import("term_chrome").tags.Tags;
const floats = @import("floats.zig");
const tiling = @import("tiling.zig");
const Value = std.json.Value;
const eq = std.mem.eql;

pub const Level = cs.Level;
pub const NotifyLevel = cs.NotifyLevel;
pub const Side = cs.Side;
pub const Style = cs.Style;
/// A popup is a float shown only on the client whose
/// ticket opened it (`client`).
pub const Layer = enum { tile, float, popup };
/// The daemon's queue bound, mirrored here.
pub const max_notifications = 64;

pub const Segment = struct {
    id: []u8,
    text: []u8,
    side: Side,
    priority: u8,
    style: Style,
    when: Tags,
    scope: []u8,
    /// Drawn inside that group's segment, as `icon` when set.
    group: ?[]u8 = null,
    icon: ?[]u8 = null,
    /// What a click on it runs, as this client.
    click: ?Click = null,
    fn deinit(self: *Segment, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.text);
        a.free(self.scope);
        self.when.deinit(a);
        if (self.group) |x| a.free(x);
        if (self.icon) |x| a.free(x);
        if (self.click) |*c| freeClick(a, c);
    }
};

/// A status click target, the same type as a key binding's target.
pub const Click = cs.Click;
fn freeClick(a: std.mem.Allocator, c: *Click) void {
    if (c.local) |x| a.free(x);
    if (c.verb) |x| a.free(x);
    if (c.args) |x| a.free(x);
    if (c.exec) |argv| {
        for (argv) |x| a.free(x);
        a.free(argv);
    }
    c.* = .{};
}
/// A segment's `click` object, owned by `a`: venomx sends `local`, `verb`
/// with `args` (a JSON object as a string) or `exec`.
fn clickFromValue(a: std.mem.Allocator, v: Value) !Click {
    if (v != .object) return error.BadEvent;
    var c: Click = .{};
    errdefer freeClick(a, &c);
    if (json.str(v, "local")) |x| c.local = try a.dupe(u8, x);
    if (json.str(v, "verb")) |x| c.verb = try a.dupe(u8, x);
    if (json.str(v, "args")) |x| c.args = try a.dupe(u8, x);
    if (json.array(v, "exec")) |items| {
        const argv = try a.alloc([]const u8, items.len);
        var n: usize = 0;
        errdefer {
            for (argv[0..n]) |x| a.free(x);
            a.free(argv);
        }
        for (items) |item| {
            if (item != .string) return error.BadEvent;
            argv[n] = try a.dupe(u8, item.string);
            n += 1;
        }
        c.exec = argv;
    }
    return c;
}

pub const Note = struct {
    id: []u8,
    text: []u8,
    level: NotifyLevel,
    pane: []u8,
    namespace: []u8,
    expires: i64,
    fn deinit(self: *Note, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.text);
        a.free(self.pane);
        a.free(self.namespace);
    }
};

pub const Pane = struct {
    id: []u8,
    session: []u8,
    tags: Tags = .{},
    level: Level = .none,
    reason: []u8 = &.{},
    layer: Layer = .tile,
    /// Float layer only: the shared spec and z-order.
    window: []u8 = &.{},
    preset: []u8 = &.{},
    geometry: floats.Partial = .{},
    title: []u8 = &.{},
    z: i64 = 0,
    /// Popups: the presentation client it was opened for (venomx's ID,
    /// learned from `popup.ticket`).
    client: []u8 = &.{},
    fn deinit(self: *Pane, a: std.mem.Allocator) void {
        a.free(self.client);
        a.free(self.id);
        a.free(self.session);
        a.free(self.reason);
        a.free(self.window);
        a.free(self.preset);
        a.free(self.title);
        self.tags.deinit(a);
    }
};

pub const Window = struct {
    id: []u8,
    session: []u8,
    /// May be empty.
    name: []u8 = &.{},
    revision: u64,
    /// Flat preorder tree; pane IDs are owned.
    nodes: []tiling.Node,
    fn deinit(self: *Window, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.session);
        a.free(self.name);
        for (self.nodes) |n| if (n.pane) |p| a.free(p);
        a.free(self.nodes);
    }
    pub fn contains(self: *const Window, pane: []const u8) bool {
        for (self.nodes) |n| if (n.pane) |p| if (eq(u8, p, pane)) return true;
        return false;
    }
};

/// What an applied event changed, so the client knows what to redraw or
/// refetch.
pub const Change = union(enum) {
    none,
    topology,
    chrome,
    /// A new notification; desk's inbox records it.
    posted: usize,
    session_removed: []const u8,
    /// `keys.changed`: reload tables with `keys.list`.
    keys,
    /// `config.changed|reloaded`: refetch status/attention/keys/floats.
    config,
};

pub const State = struct {
    a: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,
    notes: std.ArrayList(Note) = .empty,
    panes: std.ArrayList(Pane) = .empty,
    windows: std.ArrayList(Window) = .empty,
    /// Session names by ID, from `session` snapshot entities
    /// (`session.name`).
    session_names: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// Between a `state.snapshot` and its `stream.checkpoint`.
    in_snapshot: bool = false,
    /// True after the first checkpoint.
    ready: bool = false,

    pub fn init(a: std.mem.Allocator) State {
        return .{ .a = a };
    }
    pub fn deinit(self: *State) void {
        self.reset();
        self.segments.deinit(self.a);
        self.notes.deinit(self.a);
        self.panes.deinit(self.a);
        self.windows.deinit(self.a);
        self.session_names.deinit(self.a);
    }
    /// A new snapshot replaces all shared content.
    pub fn reset(self: *State) void {
        for (self.segments.items) |*s| s.deinit(self.a);
        self.segments.clearRetainingCapacity();
        for (self.notes.items) |*n| n.deinit(self.a);
        self.notes.clearRetainingCapacity();
        for (self.panes.items) |*p| p.deinit(self.a);
        self.panes.clearRetainingCapacity();
        for (self.windows.items) |*w| w.deinit(self.a);
        self.windows.clearRetainingCapacity();
        for (self.session_names.keys(), self.session_names.values()) |k, v| {
            self.a.free(k);
            self.a.free(v);
        }
        self.session_names.clearRetainingCapacity();
    }
    /// A session's name, or null when it has none.
    pub fn sessionName(self: *const State, id: []const u8) ?[]const u8 {
        const n = self.session_names.get(id) orelse return null;
        return if (n.len > 0) n else null;
    }
    fn setSessionName(self: *State, id: []const u8, name: []const u8) !void {
        const owned = try self.a.dupe(u8, name);
        errdefer self.a.free(owned);
        if (self.session_names.getPtr(id)) |old| {
            self.a.free(old.*);
            old.* = owned;
            return;
        }
        const key = try self.a.dupe(u8, id);
        errdefer self.a.free(key);
        try self.session_names.put(self.a, key, owned);
    }

    pub fn pane(self: *const State, id: []const u8) ?*Pane {
        for (self.panes.items) |*p| if (eq(u8, p.id, id)) return p;
        return null;
    }
    pub fn window(self: *const State, id: []const u8) ?*Window {
        for (self.windows.items) |*w| if (eq(u8, w.id, id)) return w;
        return null;
    }
    pub fn segment(self: *const State, id: []const u8) ?*Segment {
        for (self.segments.items) |*s| if (eq(u8, s.id, id)) return s;
        return null;
    }
    /// The window holding a pane, tiled or floating.
    pub fn windowOf(self: *const State, pane_id: []const u8) ?*Window {
        for (self.windows.items) |*w| if (w.contains(pane_id)) return w;
        if (self.pane(pane_id)) |p| if (p.window.len > 0) return self.window(p.window);
        return null;
    }

    /// Apply one event item (`{type, data, …}`).
    pub fn apply(self: *State, item: Value, now: i64) !Change {
        const kind = json.str(item, "type") orelse return error.BadEvent;
        const data = json.get(item, "data") orelse Value{ .object = .empty };
        const is = struct {
            fn f(x: []const u8, y: []const u8) bool {
                return eq(u8, x, y);
            }
        }.f;
        if (is(kind, "state.snapshot")) {
            if (!self.in_snapshot) {
                self.reset();
                self.in_snapshot = true;
            }
            const entities = json.array(data, "entities") orelse return error.BadEvent;
            for (entities) |e| try self.entity(e, now);
            return .topology;
        }
        if (is(kind, "stream.checkpoint")) {
            self.in_snapshot = false;
            self.ready = true;
            return .topology;
        }
        if (is(kind, "window.created") or is(kind, "window.layout_changed")) {
            try self.upsertWindow(data);
            return .topology;
        }
        if (is(kind, "window.removed")) {
            const id = json.str(data, "window") orelse return error.BadEvent;
            for (self.windows.items, 0..) |*w, i| if (eq(u8, w.id, id)) {
                w.deinit(self.a);
                _ = self.windows.orderedRemove(i);
                break;
            };
            return .topology;
        }
        if (is(kind, "session.removed")) return .{ .session_removed = json.str(data, "session") orelse return error.BadEvent };
        if (is(kind, "pane.created")) {
            const p = try self.paneOrNew(json.str(data, "pane") orelse return error.BadEvent, json.str(data, "session"));
            try self.setPlacement(p, data);
            return .topology;
        }
        if (is(kind, "pane.removed")) {
            const id = json.str(data, "pane") orelse return error.BadEvent;
            for (self.panes.items, 0..) |*p, i| if (eq(u8, p.id, id)) {
                p.deinit(self.a);
                _ = self.panes.orderedRemove(i);
                break;
            };
            return .topology;
        }
        if (is(kind, "pane.tags_changed")) {
            const p = try self.paneOrNew(json.str(data, "pane") orelse return error.BadEvent, null);
            try self.setTags(p, json.get(data, "tags") orelse return error.BadEvent);
            return .chrome;
        }
        if (is(kind, "pane.attention_changed")) {
            const p = try self.paneOrNew(json.str(data, "pane") orelse return error.BadEvent, null);
            try self.setAttention(p, json.str(data, "level") orelse return error.BadEvent, json.str(data, "reason") orelse "");
            return .chrome;
        }
        // A float placed into the tiling, or back.
        if (is(kind, "pane.placed")) {
            const p = try self.paneOrNew(json.str(data, "pane") orelse return error.BadEvent, null);
            try self.setPlacement(p, data);
            return .topology;
        }
        if (is(kind, "pane.raised")) {
            const p = try self.paneOrNew(json.str(data, "pane") orelse return error.BadEvent, null);
            p.z = json.int(data, "z") orelse return error.BadEvent;
            return .topology;
        }
        if (is(kind, "status.changed")) {
            try self.upsertSegment(json.get(data, "segment") orelse return error.BadEvent);
            return .chrome;
        }
        if (is(kind, "status.cleared")) {
            self.dropSegment(json.str(data, "id") orelse return error.BadEvent);
            return .chrome;
        }
        if (is(kind, "notify.posted")) return .{ .posted = try self.post(data, now) };
        if (is(kind, "notify.dismissed")) {
            self.dismiss(json.str(data, "id") orelse return error.BadEvent);
            return .chrome;
        }
        if (is(kind, "keys.changed")) return .keys;
        if (is(kind, "config.changed") or is(kind, "config.reloaded")) return .config;
        return .none;
    }

    fn entity(self: *State, e: Value, now: i64) !void {
        const t = json.str(e, "entity_type") orelse return;
        const content = json.str(e, "content") orelse return error.BadEvent;
        const parsed = try std.json.parseFromSlice(Value, self.a, content, .{});
        defer parsed.deinit();
        const v = parsed.value;
        if (eq(u8, t, "window")) return self.upsertWindow(v);
        if (eq(u8, t, "session")) return self.setSessionName(json.str(v, "session") orelse return error.BadEvent, json.str(v, "name") orelse "");
        if (eq(u8, t, "status")) return self.upsertSegment(v);
        if (eq(u8, t, "notification")) {
            _ = try self.post(v, now);
            return;
        }
        if (!eq(u8, t, "pane")) return;
        const p = try self.paneOrNew(json.str(v, "pane") orelse return error.BadEvent, json.str(v, "session"));
        if (json.get(v, "tags")) |tags| try self.setTags(p, tags);
        if (json.get(v, "attention")) |at| {
            try self.setAttention(p, json.str(at, "level") orelse return error.BadEvent, json.str(at, "reason") orelse "");
        } else try self.setAttention(p, "none", "");
        try self.setPlacement(p, v);
    }

    fn paneOrNew(self: *State, id: []const u8, session: ?[]const u8) !*Pane {
        if (self.pane(id)) |p| {
            if (session) |s| if (!eq(u8, p.session, s)) try replace(self.a, &p.session, s);
            return p;
        }
        try self.panes.ensureUnusedCapacity(self.a, 1);
        const owned_id = try self.a.dupe(u8, id);
        errdefer self.a.free(owned_id);
        self.panes.appendAssumeCapacity(.{ .id = owned_id, .session = try self.a.dupe(u8, session orelse "") });
        return &self.panes.items[self.panes.items.len - 1];
    }
    fn setTags(self: *State, p: *Pane, v: Value) !void {
        var tags = try Tags.fromValue(self.a, v);
        std.mem.swap(Tags, &p.tags, &tags);
        tags.deinit(self.a);
    }
    fn setAttention(self: *State, p: *Pane, level: []const u8, reason: []const u8) !void {
        const l = std.meta.stringToEnum(Level, level) orelse return error.BadEvent;
        try replace(self.a, &p.reason, reason);
        p.level = l;
    }
    /// `layer`, `window`, `preset`, geometry fields and `z` of a pane
    /// entity, `pane.created` or `pane.placed`. Absent means tiled.
    fn setPlacement(self: *State, p: *Pane, v: Value) !void {
        const layer = json.str(v, "layer") orelse return;
        p.layer = std.meta.stringToEnum(Layer, layer) orelse return error.BadEvent;
        if (json.str(v, "window")) |w| try replace(self.a, &p.window, w);
        // `pane.placed` of a popup (a preset re-resolved) omits `client`.
        if (json.str(v, "client")) |c| try replace(self.a, &p.client, c) else if (p.layer != .popup) try replace(self.a, &p.client, "");
        if (p.layer == .tile) return;
        // venomx publishes the resolved spec (preset, geometry, z) in a
        // `float` object; geometry at the top level is accepted too.
        const spec = json.get(v, "float") orelse v;
        try replace(self.a, &p.preset, json.str(spec, "preset") orelse "");
        var g = floats.Partial.fromValue(spec) catch return error.BadEvent;
        try replace(self.a, &p.title, g.title orelse "");
        g.title = if (g.title != null) p.title else null;
        p.geometry = g;
        if (json.int(spec, "z") orelse json.int(v, "z")) |z| p.z = z;
    }

    fn upsertWindow(self: *State, v: Value) !void {
        const id = json.str(v, "window") orelse return error.BadEvent;
        const session = json.str(v, "session") orelse return error.BadEvent;
        const items = json.array(v, "nodes") orelse return error.BadEvent;
        const nodes = try self.a.alloc(tiling.Node, items.len);
        var filled: usize = 0;
        errdefer {
            for (nodes[0..filled]) |n| if (n.pane) |x| self.a.free(x);
            self.a.free(nodes);
        }
        for (items, nodes) |item, *n| {
            const k = json.str(item, "kind") orelse return error.BadEvent;
            n.* = .{ .kind = if (eq(u8, k, "pane")) .pane else if (eq(u8, k, "split")) .split else return error.BadEvent };
            if (json.str(item, "axis")) |axis| n.axis = std.meta.stringToEnum(tiling.Axis, axis) orelse return error.BadEvent;
            if (json.int(item, "first")) |x| n.first = std.math.cast(usize, x) orelse return error.BadEvent;
            if (json.int(item, "second")) |x| n.second = std.math.cast(usize, x) orelse return error.BadEvent;
            if (json.str(item, "pane")) |x| n.pane = try self.a.dupe(u8, x);
            filled += 1;
        }
        if (!tiling.valid(nodes)) return error.BadEvent;
        const revision: u64 = if (json.int(v, "revision")) |r| std.math.cast(u64, r) orelse 0 else 0;
        try self.windows.ensureUnusedCapacity(self.a, 1);
        var w: Window = .{ .id = undefined, .session = undefined, .revision = revision, .nodes = nodes };
        w.id = try self.a.dupe(u8, id);
        errdefer self.a.free(w.id);
        w.session = try self.a.dupe(u8, session);
        errdefer self.a.free(w.session);
        w.name = try self.a.dupe(u8, json.str(v, "name") orelse "");
        errdefer comptime unreachable;
        for (self.windows.items) |*old| if (eq(u8, old.id, id)) {
            // Revisions only increase; a stale replay never rolls back.
            if (revision != 0 and old.revision > revision) return w.deinit(self.a);
            old.deinit(self.a);
            old.* = w;
            return;
        };
        self.windows.appendAssumeCapacity(w);
    }

    /// `status.changed`'s `segment`, or a `status` snapshot entity.
    fn upsertSegment(self: *State, v: Value) !void {
        const id = json.str(v, "id") orelse return error.BadEvent;
        var s: Segment = .{
            .id = try self.a.dupe(u8, id),
            .text = &.{},
            .side = std.meta.stringToEnum(Side, json.str(v, "side") orelse "right") orelse .right,
            .priority = @intCast(std.math.clamp(json.int(v, "priority") orelse 50, 0, 100)),
            .style = std.meta.stringToEnum(Style, json.str(v, "style") orelse "normal") orelse .normal,
            .when = .{},
            .scope = &.{},
        };
        errdefer s.deinit(self.a);
        s.text = try self.a.dupe(u8, json.str(v, "text") orelse return error.BadEvent);
        s.scope = try self.a.dupe(u8, json.str(v, "scope") orelse "server");
        if (json.get(v, "when")) |w| s.when = try Tags.fromValue(self.a, w);
        if (json.str(v, "group")) |g| s.group = try self.a.dupe(u8, g);
        if (json.str(v, "icon")) |i| s.icon = try self.a.dupe(u8, i);
        if (json.get(v, "click")) |c| if (c != .null) {
            s.click = try clickFromValue(self.a, c);
        };
        for (self.segments.items) |*old| if (eq(u8, old.id, id)) {
            old.deinit(self.a);
            old.* = s;
            return;
        };
        try self.segments.append(self.a, s);
    }
    fn dropSegment(self: *State, id: []const u8) void {
        for (self.segments.items, 0..) |*s, i| if (eq(u8, s.id, id)) {
            s.deinit(self.a);
            _ = self.segments.orderedRemove(i);
            return;
        };
    }

    fn post(self: *State, v: Value, now: i64) !usize {
        const id = json.str(v, "id") orelse return error.BadEvent;
        self.dismiss(id);
        var n: Note = .{ .id = &.{}, .text = &.{}, .level = std.meta.stringToEnum(NotifyLevel, json.str(v, "level") orelse "info") orelse .info, .pane = &.{}, .namespace = &.{}, .expires = now + (json.int(v, "ttl_ms") orelse 8000) };
        errdefer n.deinit(self.a);
        n.id = try self.a.dupe(u8, id);
        n.text = try self.a.dupe(u8, json.str(v, "text") orelse return error.BadEvent);
        n.pane = try self.a.dupe(u8, json.str(v, "pane") orelse "");
        n.namespace = try self.a.dupe(u8, json.str(v, "namespace") orelse "");
        try self.notes.append(self.a, n);
        if (self.notes.items.len > max_notifications) {
            var old = self.notes.orderedRemove(0);
            old.deinit(self.a);
        }
        return self.notes.items.len - 1;
    }
    pub fn dismiss(self: *State, id: []const u8) void {
        for (self.notes.items, 0..) |*n, i| if (eq(u8, n.id, id)) {
            n.deinit(self.a);
            _ = self.notes.orderedRemove(i);
            return;
        };
    }
    /// The newest unexpired notification; expired ones are dropped.
    pub fn newest(self: *State, now: i64) ?*const Note {
        var i: usize = 0;
        while (i < self.notes.items.len) {
            if (self.notes.items[i].expires <= now) {
                var n = self.notes.orderedRemove(i);
                n.deinit(self.a);
            } else i += 1;
        }
        return if (self.notes.items.len > 0) &self.notes.items[self.notes.items.len - 1] else null;
    }
    /// Panes of `session` whose attention is not `none`, in window order
    /// then float order.
    pub fn attentionCount(self: *const State, session: []const u8) usize {
        var count: usize = 0;
        for (self.panes.items) |p| if (p.level != .none and eq(u8, p.session, session)) {
            count += 1;
        };
        return count;
    }
};

fn replace(a: std.mem.Allocator, slot: *[]u8, value: []const u8) !void {
    const owned = try a.dupe(u8, value);
    a.free(slot.*);
    slot.* = owned;
}

/// Test helper: apply a JSON event line.
pub fn applyLine(state: *State, line: []const u8, now: i64) !Change {
    const parsed = try std.json.parseFromSlice(Value, state.a, line, .{});
    defer parsed.deinit();
    return state.apply(parsed.value, now);
}

test "snapshot then events build the shared model" {
    const a = std.testing.allocator;
    var s = State.init(a);
    defer s.deinit();
    _ = try applyLine(&s,
        \\{"type":"state.snapshot","data":{"entities":[
        \\ {"entity_type":"window","content":"{\"window\":\"w0\",\"session\":\"s0\",\"revision\":2,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p1\"}]}"},
        \\ {"entity_type":"pane","content":"{\"pane\":\"p1\",\"session\":\"s0\",\"tags\":[{\"key\":\"owner\",\"value\":\"venom\"}],\"attention\":{\"level\":\"urgent\",\"reason\":\"approval\"}}"},
        \\ {"entity_type":"status","content":"{\"id\":\"user.build\",\"text\":\"ok\",\"style\":\"ok\",\"priority\":40}"}
        \\]}}
    , 0);
    try std.testing.expect(s.in_snapshot);
    _ = try applyLine(&s, "{\"type\":\"stream.checkpoint\",\"data\":{}}", 0);
    try std.testing.expect(s.ready and !s.in_snapshot);
    try std.testing.expectEqual(@as(usize, 1), s.windows.items.len);
    try std.testing.expect(s.window("w0").?.contains("p1"));
    try std.testing.expectEqual(Level.urgent, s.pane("p1").?.level);
    try std.testing.expectEqualStrings("venom", s.pane("p1").?.tags.get("owner").?);
    try std.testing.expectEqual(@as(usize, 1), s.attentionCount("s0"));
    try std.testing.expectEqual(Style.ok, s.segment("user.build").?.style);

    _ = try applyLine(&s, "{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p1\",\"level\":\"none\",\"reason\":\"\"}}", 0);
    try std.testing.expectEqual(@as(usize, 0), s.attentionCount("s0"));
    _ = try applyLine(&s, "{\"type\":\"status.cleared\",\"data\":{\"id\":\"user.build\",\"reason\":\"disconnect\"}}", 0);
    try std.testing.expect(s.segment("user.build") == null);
    // A stale window revision never rolls topology back.
    _ = try applyLine(&s, "{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}", 0);
    try std.testing.expect(s.window("w0").?.contains("p1"));
    try std.testing.expect((try applyLine(&s, "{\"type\":\"keys.changed\",\"data\":{\"layer\":\"product\",\"table\":\"venom\",\"revision\":3}}", 0)) == .keys);
}

test "floats and notifications" {
    const a = std.testing.allocator;
    var s = State.init(a);
    defer s.deinit();
    _ = try applyLine(&s, "{\"type\":\"pane.created\",\"data\":{\"pane\":\"p7\",\"session\":\"s0\",\"window\":\"w0\",\"layer\":\"float\",\"preset\":\"venom.settings\",\"title\":\"log\",\"z\":1}}", 0);
    const p = s.pane("p7").?;
    try std.testing.expectEqual(Layer.float, p.layer);
    try std.testing.expectEqualStrings("venom.settings", p.preset);
    try std.testing.expectEqualStrings("log", p.geometry.title.?);
    _ = try applyLine(&s, "{\"type\":\"pane.raised\",\"data\":{\"pane\":\"p7\",\"z\":4}}", 0);
    try std.testing.expectEqual(@as(i64, 4), s.pane("p7").?.z);
    _ = try applyLine(&s, "{\"type\":\"pane.placed\",\"data\":{\"pane\":\"p7\",\"layer\":\"float\",\"float\":{\"width\":\"30%\"}}}", 0);
    try std.testing.expectEqual(floats.Size{ .percent = 30 }, s.pane("p7").?.geometry.width.?);
    try std.testing.expect(s.pane("p7").?.geometry.title == null);
    // venomx's wire form: the resolved spec and z under `float`; a popup
    // names the client it was opened for, kept across `pane.placed`.
    _ = try applyLine(&s, "{\"type\":\"pane.created\",\"data\":{\"pane\":\"p8\",\"session\":\"s0\",\"window\":\"w0\",\"layer\":\"popup\",\"client\":\"c0\",\"float\":{\"preset\":\"venom.settings\",\"width\":\"80%\",\"height\":\"80%\",\"anchor\":\"top_left\",\"x\":0,\"y\":0,\"min_cols\":20,\"min_rows\":5,\"border\":\"rounded\",\"z\":7}}}", 0);
    const pop = s.pane("p8").?;
    try std.testing.expectEqual(Layer.popup, pop.layer);
    try std.testing.expectEqual(@as(i64, 7), pop.z);
    try std.testing.expectEqualStrings("c0", pop.client);
    try std.testing.expectEqual(floats.Anchor.@"top-left", pop.geometry.anchor.?);
    _ = try applyLine(&s, "{\"type\":\"pane.placed\",\"data\":{\"pane\":\"p8\",\"window\":\"w0\",\"layer\":\"popup\",\"float\":{\"width\":\"90%\",\"height\":\"80%\",\"anchor\":\"center\",\"border\":\"rounded\",\"z\":7}}}", 0);
    try std.testing.expectEqualStrings("c0", s.pane("p8").?.client);
    try std.testing.expectEqual(floats.Size{ .percent = 90 }, s.pane("p8").?.geometry.width.?);

    const ch = try applyLine(&s, "{\"type\":\"notify.posted\",\"data\":{\"id\":\"n1\",\"text\":\"done\",\"level\":\"warn\",\"ttl_ms\":1000,\"namespace\":\"venom\"}}", 100);
    try std.testing.expect(ch == .posted);
    try std.testing.expectEqualStrings("done", s.newest(500).?.text);
    try std.testing.expect(s.newest(1100) == null);
    var i: usize = 0;
    while (i < max_notifications + 3) : (i += 1) {
        const line = try std.fmt.allocPrint(a, "{{\"type\":\"notify.posted\",\"data\":{{\"id\":\"m{d}\",\"text\":\"x\"}}}}", .{i});
        defer a.free(line);
        _ = try applyLine(&s, line, 0);
    }
    try std.testing.expectEqual(@as(usize, max_notifications), s.notes.items.len);
}
