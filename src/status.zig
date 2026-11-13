//! The status line and the rail's segment list:
//! the built-in `venomx.*` segments this client computes, the shared
//! segments visible to it and the config's own `user.*` sources, through the
//! `status` config's lists, slot overrides, templates and groups. The ids,
//! default order, sources and click targets are the ones `venomx attach`
//! uses, so for one config both clients show the same segments; only layout
//! and truncation differ with each client's width and shape.
const std = @import("std");
const shared = @import("shared.zig");
const Side = shared.Side;
const Style = shared.Style;

const cs = @import("term_chrome").status;

/// `status` config, read from the daemon's `config.get --key status` as
/// `venomx attach` does, so one setting drives both clients.
pub const Config = cs.Config;
/// `attention` config.
pub const AttentionConfig = cs.AttentionConfig;
pub const Click = cs.Click;
pub const template = cs.template;

/// Parse a ZON config value (the `content` of `config.get`) into `T` in
/// `arena`. Unknown fields are ignored so newer daemons stay readable.
pub fn parseConfig(comptime T: type, arena: std.mem.Allocator, content: []const u8) !T {
    const source = try arena.dupeSentinel(u8, content, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) err else error.BadConfig;
}

// Glyphs, items, groups and the layout are venom-term's
// `chrome.status`, shared with `venomx attach`.
pub const glyph = cs.glyph;
pub const levelStyle = cs.levelStyle;
pub const notifyStyle = cs.notifyStyle;
pub const Item = cs.Item;
pub const Placed = cs.Placed;
pub const separator = cs.separator;
pub const width = cs.width;
pub const layout = cs.layout;
pub const render = cs.render;
pub const hit = cs.hit;

/// `venomx attach`'s marks and cuts.
const active_mark = "▸";
const nbsp = "\u{a0}";
const session_name_cells = 24;
const window_name_cells = 16;
/// The pane blocks keep at least this many cells when other items crowd them.
const blocks_min: usize = 12;

pub const Window = struct { id: []const u8, name: []const u8 = "" };

/// What this client contributes to the built-ins. All of it is per-client
/// view state; `state` is the daemon's content.
pub const Context = struct {
    session: []const u8,
    /// Windows of the session in ID order, and the one this client shows.
    windows: []const Window,
    active: ?[]const u8,
    focus: ?[]const u8,
    /// `venomx.panes`: the shown window's tiles in layout order, then a
    /// focused float or popup.
    panes: []const []const u8 = &.{},
    zoomed: bool = false,
    /// Inside a venomx pane (`venomx.nested`).
    nested: bool = false,
    /// `venomx.mode`: `LEADER`, `LEADER <table>`, `LOCK`, or empty.
    mode: []const u8 = "",
    message: []const u8 = "",
    /// `venomx.clock` without a template.
    clock: []const u8,
    /// For `{clock}` in templates; null leaves it empty.
    clock_now: ?template.Clock = null,
    now: i64,
    host: []const u8 = "",
    user: []const u8 = "",
    /// Ids `toggle-segment` flipped on this client.
    toggled: []const []const u8 = &.{},
    /// Columns of the status line, for the pane blocks' fitting.
    cols: u16 = 80,
};

/// variables as this client sees them: its session, the shown
/// window (or `window`, inside `venomx.windows`) and the focused pane (or
/// `pane`, inside `venomx.panes`). The desk core has no pane content, so
/// `pane.cwd`, `pane.process`, `pane.command`, `pane.title` and
/// `pane.program` are empty here, and a pane's label is its ID (venomx's
/// fallback for a pane with neither cwd nor process).
const Vars = struct {
    a: std.mem.Allocator,
    state: *const shared.State,
    ctx: *const Context,
    window: ?Window = null,
    pane: ?[]const u8 = null,

    fn lookup(self: *const Vars) template.Lookup {
        return .{ .ctx = self, .get = get, .clock_now = self.ctx.clock_now };
    }
    fn get(ptr: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const Vars = @ptrCast(@alignCast(ptr.?));
        return self.variable(name) catch null;
    }
    fn variable(self: *const Vars, name: []const u8) !?[]const u8 {
        const eq = std.mem.eql;
        const ctx = self.ctx;
        if (eq(u8, name, "session.id")) return ctx.session;
        if (eq(u8, name, "session.name")) return self.state.sessionName(ctx.session) orelse ctx.session;
        if (std.mem.startsWith(u8, name, "window.")) {
            const w = self.window orelse activeWindow(ctx) orelse return null;
            const rank = windowRank(ctx, w.id);
            const label = try windowLabel(self.a, w.name);
            const part = name["window.".len..];
            if (eq(u8, part, "index")) return try std.fmt.allocPrint(self.a, "{d}", .{rank + 1});
            if (eq(u8, part, "name")) return label;
            if (eq(u8, part, "id")) return w.id;
            if (eq(u8, part, "label")) return if (label.len > 0) try std.fmt.allocPrint(self.a, "{d}:{s}", .{ rank + 1, label }) else try std.fmt.allocPrint(self.a, "{d}", .{rank + 1});
            return null;
        }
        if (std.mem.startsWith(u8, name, "pane.")) {
            const p = self.pane orelse ctx.focus orelse return null;
            const part = name["pane.".len..];
            if (eq(u8, part, "id")) return p;
            if (std.mem.startsWith(u8, part, "tag.")) return if (self.state.pane(p)) |info| info.tags.get(part["tag.".len..]) else null;
            if (eq(u8, part, "label")) return try blockText(self.a, p);
            return null;
        }
        if (eq(u8, name, "attention.count")) {
            const n = self.state.attentionCount(ctx.session);
            return if (n > 0) try std.fmt.allocPrint(self.a, "{d}", .{n}) else null;
        }
        if (eq(u8, name, "host")) return if (ctx.host.len > 0) ctx.host else null;
        if (eq(u8, name, "user")) return if (ctx.user.len > 0) ctx.user else null;
        return null;
    }
};

fn activeWindow(ctx: *const Context) ?Window {
    const id = ctx.active orelse return null;
    for (ctx.windows) |w| if (std.mem.eql(u8, w.id, id)) return w;
    return null;
}
/// 1-based index: the window's rank by ID.
fn windowRank(ctx: *const Context, id: []const u8) usize {
    for (ctx.windows, 0..) |w, i| if (std.mem.eql(u8, w.id, id)) return i;
    return 0;
}
/// A window name cleaned to one line and cut to `window_name_cells`.
fn windowLabel(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const cleaned = std.mem.trim(u8, try template.clean(a, name), " ");
    return cutCells(a, cleaned, window_name_cells, false);
}
/// The first `cells` cells of `text`, keeping clusters whole, with `…` in
/// the last cell when `ellipsis` and it was cut.
fn cutCells(a: std.mem.Allocator, text: []const u8, cells: usize, ellipsis: bool) ![]const u8 {
    if (width(text) <= cells) return text;
    const room = if (ellipsis) cells -| 1 else cells;
    var it: cs.cell_width.Iterator = .{ .text = text };
    var n: usize = 0;
    var end: usize = 0;
    while (it.next()) |g| {
        if (n + g.width > room) break;
        n += g.width;
        end = it.pos;
    }
    return if (ellipsis) std.fmt.allocPrint(a, "{s}…", .{text[0..end]}) else text[0..end];
}
/// One pane's block, ` <label> `: the desk core has no cwd or process, so
/// the label is the pane ID, as venomx draws a pane with neither.
fn blockText(a: std.mem.Allocator, pane: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, " {s} ", .{pane});
}

fn renderFormat(a: std.mem.Allocator, config: Config, id: []const u8, vars: *const Vars) !?[]const u8 {
    const f = config.format(id) orelse return null;
    return template.renderSource(a, f, .segment, vars.lookup());
}

fn windowsText(a: std.mem.Allocator, state: *const shared.State, config: Config, ctx: *const Context) ![]const u8 {
    var ws: std.ArrayList(u8) = .empty;
    // A `venomx.windows` template renders each window.
    if (config.format("venomx.windows")) |f| {
        for (ctx.windows) |w| {
            const vars: Vars = .{ .a = a, .state = state, .ctx = ctx, .window = w };
            const text = (try template.renderSource(a, f, .segment, vars.lookup())) orelse break;
            if (text.len == 0) continue;
            const active = ctx.active != null and std.mem.eql(u8, ctx.active.?, w.id);
            try ws.print(a, "{s}{s}", .{ if (ws.items.len > 0) " " else "", if (active) active_mark else "" });
            try appendNbsp(a, &ws, text);
        } else return ws.items;
        ws.clearRetainingCapacity();
    }
    for (ctx.windows, 0..) |w, rank| {
        const active = ctx.active != null and std.mem.eql(u8, ctx.active.?, w.id);
        try ws.print(a, "{s}{s}{d}", .{ if (ws.items.len > 0) " " else "", if (active) active_mark else "", rank + 1 });
        const name = try windowLabel(a, w.name);
        if (name.len > 0) {
            try ws.append(a, ':');
            try appendNbsp(a, &ws, name);
        }
    }
    return ws.items;
}
/// A name may hold spaces; U+00A0 keeps it one word.
fn appendNbsp(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |ch| if (ch == ' ') try out.appendSlice(a, nbsp) else try out.append(a, ch);
}

fn panesText(a: std.mem.Allocator, state: *const shared.State, config: Config, ctx: *const Context) ![]const u8 {
    const entry = config.segment("venomx.panes");
    // `.panes = .focused` lists the focused pane alone.
    const listed: []const []const u8 = if (entry != null and entry.?.panes == .focused)
        (if (ctx.focus) |f| try a.dupe([]const u8, &.{f}) else &.{})
    else
        ctx.panes;
    const format = if (entry) |e| e.format else null;
    var line: std.ArrayList(u8) = .empty;
    for (listed, 0..) |p, i| {
        if (i > 0) try line.append(a, ' ');
        if (format) |f| {
            const vars: Vars = .{ .a = a, .state = state, .ctx = ctx, .pane = p };
            const text = (try template.renderSource(a, f, .segment, vars.lookup())) orelse p;
            try line.print(a, " {s} ", .{text});
        } else try line.appendSlice(a, try blockText(a, p));
    }
    return line.items;
}

/// The focused pane's notes (`[Z]`, its float layer, the attention
/// reason), space-separated; empty when it has none.
fn paneNotes(a: std.mem.Allocator, state: *const shared.State, ctx: *const Context) ![]const u8 {
    const f = ctx.focus orelse return "";
    var line: std.ArrayList(u8) = .empty;
    if (ctx.zoomed) try line.appendSlice(a, " [Z]");
    const info = state.pane(f);
    if (info) |p| if (p.layer != .tile) try line.print(a, " [{s}]", .{@tagName(p.layer)});
    if (info) |p| if (p.level != .none and p.reason.len > 0) try line.print(a, " {s}", .{p.reason});
    return if (line.items.len > 0) line.items[1..] else "";
}

/// Built-in segments, the visible shared ones and the config's own
/// `user.*` sources, through `config`, in the order
/// and with the ids, priorities and sources of `venomx attach`. Text is
/// allocated in `a` (an arena).
pub fn items(a: std.mem.Allocator, state: *shared.State, config: Config, ctx: Context) ![]Item {
    var b: cs.Builder = .{ .a = a, .config = config, .toggled = ctx.toggled };
    const vars: Vars = .{ .a = a, .state = state, .ctx = &ctx };
    const session_text = if (try renderFormat(a, config, "venomx.session", &vars)) |t| t else blk: {
        const name = state.sessionName(ctx.session) orelse ctx.session;
        const shown = std.mem.trim(u8, try cutCells(a, try template.clean(a, name), session_name_cells, false), " ");
        break :blk if (shown.len > 0) shown else ctx.session;
    };
    if (session_text.len > 0) try b.add("venomx.session", try std.fmt.allocPrint(a, " {s} ", .{session_text}), .left, 100, .normal);
    try b.add("venomx.windows", try windowsText(a, state, config, &ctx), .left, 90, .normal);
    if (ctx.nested) try b.add("venomx.nested", " NESTED ", .left, 96, .normal);
    if (ctx.mode.len > 0) try b.add("venomx.mode", try std.fmt.allocPrint(a, " {s} ", .{ctx.mode}), .left, 95, .normal);
    try b.add("venomx.panes", try panesText(a, state, config, &ctx), .left, 85, .normal);
    // An empty `venomx.pane` template means the fixed notes.
    const notes = try renderFormat(a, config, "venomx.pane", &vars);
    try b.add("venomx.pane", if (notes != null and config.format("venomx.pane").?.len > 0) notes.? else try paneNotes(a, state, &ctx), .left, 84, .normal);
    const focused = if (ctx.focus) |f| state.pane(f) else null;
    try b.add("venomx.message", ctx.message, .right, 99, .normal);
    if (state.newest(ctx.now)) |n| try b.add("venomx.notify", n.text, .right, 85, notifyStyle(n.level));
    // The tray draws the `tray` group's members.
    try b.addSegment(.{ .id = "venomx.tray", .side = .right, .priority = 60, .group_of = "tray" });
    const count = state.attentionCount(ctx.session);
    if (count > 0) try b.add("venomx.attention", try std.fmt.allocPrint(a, "{d} attention", .{count}), .right, 80, .warn);
    const clock = if (try renderFormat(a, config, "venomx.clock", &vars)) |t| t else ctx.clock;
    try b.add("venomx.clock", clock, .right, 10, .normal);
    for (state.segments.items) |seg| {
        if (std.mem.startsWith(u8, seg.id, "venomx.")) continue;
        if (!std.mem.eql(u8, seg.scope, "server") and !std.mem.eql(u8, seg.scope, ctx.session)) continue;
        if (seg.when.len() > 0) {
            const info = focused orelse continue;
            if (!info.tags.matches(seg.when.slice())) continue;
        }
        try b.addSegment(.{ .id = seg.id, .text = seg.text, .side = seg.side, .priority = seg.priority, .style = seg.style, .group = seg.group, .icon = seg.icon });
    }
    try b.addConfigured(vars.lookup());
    const out = try b.items();
    try fitPanes(a, out, ctx.cols);
    return out;
}

/// The pane blocks give way to the other items, as in `venomx attach`
///: with less room than they need they are cut with `…`,
/// keeping `blocks_min` cells at least.
fn fitPanes(a: std.mem.Allocator, list: []Item, cols: u16) !void {
    const at = for (list, 0..) |it, i| {
        if (std.mem.eql(u8, it.id, "venomx.panes")) break i;
    } else return;
    var others: std.ArrayList(Item) = .empty;
    for (list, 0..) |it, i| if (i != at) try others.append(a, it);
    var used = [3]usize{ 0, 0, 0 };
    var count = [3]usize{ 0, 0, 0 };
    for (try layout(a, others.items, cols)) |placed| {
        const side = @backingInt(placed.side);
        used[side] += width(placed.text) + (if (count[side] > 0) @as(usize, cs.separator_width) else 0);
        count[side] += 1;
    }
    const own = @backingInt(list[at].side);
    var sides: usize = 1;
    for (count, 0..) |n, i| if (i != own and n > 0) {
        sides += 1;
    };
    const lead: usize = if (count[own] > 0) @as(usize, cs.separator_width) else 0;
    const room = @max(@as(usize, cols) -| (used[0] + used[1] + used[2] + lead + sides - 1), blocks_min);
    list[at].text = try cutCells(a, list[at].text, room, true);
}

/// The click target of a segment or group member. A config
/// slot override's `click` wins over the one its product set.
pub fn clickOf(config: Config, state: *const shared.State, id: []const u8) ?Click {
    if (config.segment(id)) |s| if (s.click) |c| return c;
    const seg = state.segment(id) orelse return null;
    return seg.click;
}

// ------------------------------------------------------------------ rail

/// One row of the rail's segment list. `id` is what a click on it runs
/// (null for a group's heading); a group member is indented under it.
pub const RailRow = struct {
    id: ?[]const u8,
    text: []const u8,
    style: Style,
    member: bool = false,
};

fn drawLess(_: void, x: Item, y: Item) bool {
    if (x.side != y.side) return @backingInt(x.side) < @backingInt(y.side);
    const xo = x.order orelse std.math.maxInt(u16);
    const yo = y.order orelse std.math.maxInt(u16);
    if (xo != yo) return xo < yo;
    if (x.priority != y.priority) return x.priority > y.priority;
    return std.mem.lessThan(u8, x.id, y.id);
}

/// The rail's segment list (a group may be drawn as a list):
/// the same items as the status line, one per row in the line's drawing
/// order (left, centre, right), with nothing dropped for width. A group is
/// a heading row, then one row per member: its icon and text when it has
/// both. Allocated in `a`.
pub fn railRows(a: std.mem.Allocator, state: *const shared.State, list: []const Item) ![]RailRow {
    const sorted = try a.dupe(Item, list);
    std.mem.sort(Item, sorted, {}, drawLess);
    var out: std.ArrayList(RailRow) = .empty;
    for (sorted) |it| {
        if (it.members.len == 0) {
            const text = std.mem.trim(u8, it.text, " ");
            if (text.len > 0) try out.append(a, .{ .id = it.id, .text = text, .style = it.style });
            continue;
        }
        const heading = if (std.mem.indexOfScalar(u8, it.id, '.')) |dot| it.id[dot + 1 ..] else it.id;
        try out.append(a, .{ .id = null, .text = heading, .style = .muted });
        for (it.members) |m| {
            var text = m.text;
            if (state.segment(m.id)) |seg| if (seg.icon != null and seg.text.len > 0 and std.mem.eql(u8, m.text, seg.icon.?)) {
                const g = glyph(m.style);
                text = if (g.len > 0) try std.fmt.allocPrint(a, "{s} {s} {s}", .{ seg.icon.?, g, seg.text }) else try std.fmt.allocPrint(a, "{s} {s}", .{ seg.icon.?, seg.text });
            };
            try out.append(a, .{ .id = m.id, .text = text, .style = m.style, .member = true });
        }
    }
    return out.items;
}

// ----------------------------------------------------------------- tests

const testing = std.testing;
fn find(list: []const Item, id: []const u8) ?Item {
    for (list) |i| if (std.mem.eql(u8, i.id, id)) return i;
    return null;
}

test "items: venomx's built-ins, scope, when, slot overrides and show" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = shared.State.init(testing.allocator);
    defer state.deinit();
    _ = try shared.applyLine(&state, "{\"type\":\"pane.created\",\"data\":{\"pane\":\"p1\",\"session\":\"s0\"}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"pane.tags_changed\",\"data\":{\"pane\":\"p1\",\"tags\":{\"owner\":\"venom\"}}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p1\",\"level\":\"urgent\",\"reason\":\"approval\"}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"user.all\",\"text\":\"all\",\"style\":\"ok\"}}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"user.s1\",\"text\":\"other\",\"scope\":\"s1\"}}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom-os.agent\",\"text\":\"agent only\",\"when\":{\"owner\":\"venom\"}}}}", 0);
    const ctx: Context = .{ .session = "s0", .windows = &.{ .{ .id = "w0", .name = "shell" }, .{ .id = "w1" } }, .active = "w0", .focus = null, .clock = "14:02", .now = 0 };
    const unfocused = try items(a, &state, .{}, ctx);
    try testing.expectEqualStrings("● all", find(unfocused, "user.all").?.text);
    try testing.expect(find(unfocused, "user.s1") == null);
    try testing.expect(find(unfocused, "venom-os.agent") == null);
    try testing.expectEqualStrings("▲ 1 attention", find(unfocused, "venomx.attention").?.text);
    try testing.expectEqualStrings("▸1:shell 2", find(unfocused, "venomx.windows").?.text);
    try testing.expectEqualStrings(" s0 ", find(unfocused, "venomx.session").?.text);
    var focused_ctx = ctx;
    focused_ctx.focus = "p1";
    focused_ctx.panes = &.{"p1"};
    focused_ctx.zoomed = true;
    const config: Config = .{ .segments = &.{ .{ .id = "venomx.clock", .show = false }, .{ .id = "user.all", .priority = 70 } } };
    const focused = try items(a, &state, config, focused_ctx);
    try testing.expect(find(focused, "venom-os.agent") != null);
    try testing.expect(find(focused, "venomx.clock") == null);
    try testing.expectEqual(@as(u8, 70), find(focused, "user.all").?.priority);
    try testing.expectEqualStrings("[Z] approval", find(focused, "venomx.pane").?.text);
    try testing.expectEqualStrings(" p1 ", find(focused, "venomx.panes").?.text);
    // `toggle-segment` flips one id on this client only.
    focused_ctx.toggled = &.{ "venomx.clock", "user.all" };
    const toggled = try items(a, &state, config, focused_ctx);
    try testing.expect(find(toggled, "venomx.clock") != null);
    try testing.expect(find(toggled, "user.all") == null);
}

test "templates for built-ins and user sources, and the default order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = shared.State.init(testing.allocator);
    defer state.deinit();
    _ = try shared.applyLine(&state, "{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"entity_type\":\"session\",\"content\":\"{\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"work\\\"}\"}]}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"pane.created\",\"data\":{\"pane\":\"p4\",\"session\":\"s0\"}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"pane.tags_changed\",\"data\":{\"pane\":\"p4\",\"tags\":{\"branch\":\"main\"}}}", 0);
    const config: Config = .{
        .center = &.{"venomx.clock"},
        .right = &.{ "venomx.message", "user.host" },
        .segments = &.{
            .{ .id = "venomx.panes", .panes = .focused, .format = "<{pane.id}>" },
            .{ .id = "venomx.clock", .format = "{clock:%H:%M}" },
            .{ .id = "venomx.windows", .format = "{window.index}" },
            .{ .id = "venomx.pane", .format = "{pane.tag.branch|-}" },
            .{ .id = "user.host", .text = "devbox", .side = .left, .priority = 20 },
            .{ .id = "user.where", .format = "{session.name}[@{host}]", .side = .left },
        },
    };
    const ctx: Context = .{ .session = "s0", .windows = &.{ .{ .id = "w0" }, .{ .id = "w2" } }, .active = "w2", .focus = "p4", .panes = &.{ "p0", "p4" }, .clock = "--:--", .clock_now = template.Clock.fromEpoch(14 * 3600 + 2 * 60, 0), .now = 0 };
    const out = try items(a, &state, config, ctx);
    try testing.expectEqualStrings(" work ", find(out, "venomx.session").?.text);
    try testing.expectEqualStrings(" <p4> ", find(out, "venomx.panes").?.text);
    try testing.expectEqualStrings("14:02", find(out, "venomx.clock").?.text);
    try testing.expectEqual(Side.center, find(out, "venomx.clock").?.side);
    try testing.expectEqualStrings("1 ▸2", find(out, "venomx.windows").?.text);
    try testing.expectEqualStrings("main", find(out, "venomx.pane").?.text);
    // A listed id goes where its list says; an unlisted one to its side.
    try testing.expectEqual(Side.right, find(out, "user.host").?.side);
    // `[@{host}]` drops whole: this client knows no host.
    try testing.expectEqualStrings("work", find(out, "user.where").?.text);
    // Default lists draw in order.
    const line = try render(a, try layout(a, try items(a, &state, .{}, ctx), 60), 60);
    try testing.expect(std.mem.startsWith(u8, line, " work  │ 1 ▸2 │  p0   p4 "));
    try testing.expect(std.mem.endsWith(u8, line, "--:--"));
}

test "tray: pushed members as icons on the line, as a list in the rail; clicks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state = shared.State.init(testing.allocator);
    defer state.deinit();
    _ = try shared.applyLine(&state, "{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom-os.wifi\",\"text\":\"wifi\",\"icon\":\"📶\",\"group\":\"tray\",\"priority\":40,\"click\":{\"verb\":\"pane.popup\",\"args\":\"{\\\"preset\\\":\\\"venom-os.wifi\\\"}\"}}}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom-os.battery\",\"text\":\"81%\",\"style\":\"ok\",\"group\":\"tray\",\"priority\":50,\"click\":{\"exec\":[\"bat\",\"{pane}\"]}}}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom.agents\",\"text\":\"2 running\",\"click\":{\"local\":\"inbox\"}}}}", 0);
    const ctx: Context = .{ .session = "s0", .windows = &.{}, .active = null, .focus = null, .clock = "14:02", .now = 0 };
    const config: Config = .{ .segments = &.{.{ .id = "venom.agents", .click = .{ .local = "palette" } }} };
    const out = try items(a, &state, config, ctx);
    const tray = find(out, "venomx.tray").?;
    try testing.expectEqualStrings("● 81% 📶", tray.text);
    try testing.expect(find(out, "venom-os.wifi") == null);
    const placed = try layout(a, out, 80);
    var x: u16 = 0;
    for (placed) |p| if (std.mem.eql(u8, p.id, "venomx.tray")) {
        x = p.x;
    };
    try testing.expectEqualStrings("venom-os.battery", hit(placed, x).?);
    try testing.expectEqualStrings("venom-os.wifi", hit(placed, x + 6).?);
    // Clicks: the product's target, unless config overrides it.
    try testing.expectEqualStrings("pane.popup", clickOf(config, &state, "venom-os.wifi").?.verb.?);
    try testing.expectEqualStrings("bat", clickOf(config, &state, "venom-os.battery").?.exec.?[0]);
    try testing.expectEqualStrings("palette", clickOf(config, &state, "venom.agents").?.local.?);
    try testing.expect(clickOf(config, &state, "venomx.clock") == null);
    // The rail: the tray is a heading and one row per member.
    const rows = try railRows(a, &state, out);
    var heading: ?usize = null;
    for (rows, 0..) |r, i| if (r.id == null) {
        heading = i;
    };
    try testing.expectEqualStrings("tray", rows[heading.?].text);
    try testing.expectEqualStrings("venom-os.battery", rows[heading.? + 1].id.?);
    try testing.expectEqualStrings("● 81%", rows[heading.? + 1].text);
    try testing.expectEqualStrings("📶 wifi", rows[heading.? + 2].text);
    try testing.expect(rows[heading.? + 2].member);
    try testing.expectEqualStrings("s0", rows[0].text);
    // Cleared members: no tray, on the line or in the rail.
    _ = try shared.applyLine(&state, "{\"type\":\"status.cleared\",\"data\":{\"id\":\"venom-os.wifi\",\"reason\":\"clear\"}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"status.cleared\",\"data\":{\"id\":\"venom-os.battery\",\"reason\":\"clear\"}}", 0);
    const after = try items(a, &state, config, ctx);
    try testing.expect(find(after, "venomx.tray") == null);
    for (try railRows(a, &state, after)) |r| try testing.expect(r.id != null);
}

test "config parses the daemon's ZON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try parseConfig(Config, arena.allocator(), ".{ .position = .bottom, .left = .{\"venomx.session\"}, .unlisted = .hide, .future = 1 }");
    try testing.expectEqual(Config.Position.bottom, c.position);
    try testing.expectEqual(Config.Unlisted.hide, c.unlisted);
    try testing.expectError(error.BadConfig, parseConfig(Config, arena.allocator(), ".{ .position = .sideways }"));
}
