//! Draws a `Desk` with real cells: the frame `Desk.frame` describes as
//! text (status line, tiles of the shown window with their borders and
//! attention markers, floats in z-order, the overlay), with pane content
//! from each pane's venom-term Vt and styles from venom-term theme roles.
const std = @import("std");
const term = @import("venom-term");
const desk_mod = @import("venom-desk");
const PaneStream = @import("pane_stream.zig").PaneStream;
const Desk = desk_mod.Desk;
const floats = desk_mod.floats;
const tiling = desk_mod.tiling;
const shared = desk_mod.shared;
const status = desk_mod.status;
const Surface = term.Surface;
const Style = term.Style;
const Region = term.Region;
const Chrome = term.theme.Chrome;
const eq = std.mem.eql;

/// One pane this client shows, where, and the cells its content gets.
pub const Shown = struct {
    pane: []const u8,
    rect: floats.Rect,
    inner: floats.Rect,
    border: floats.Border,
    float: bool,
    title: []const u8 = "",
};

fn shrink(r: floats.Rect, border: floats.Border) floats.Rect {
    if (border == .none or r.width < 3 or r.height < 3) return r;
    return .{ .x = r.x + 1, .y = r.y + 1, .width = r.width - 2, .height = r.height - 2 };
}

/// The panes this client shows, bottom first: the shown window's tiles (or
/// only the focused one while zoomed), then visible floats in z-order.
/// Memory belongs to `a`; pane IDs borrow the desk's state.
pub fn layout(d: *Desk, a: std.mem.Allocator) ![]Shown {
    var out: std.ArrayList(Shown) = .empty;
    const area = d.windowArea();
    if (area.width == 0 or area.height == 0) return out.toOwnedSlice(a);
    if (d.currentWindow()) |w| {
        for (try tiling.leaves(a, w.nodes, area)) |leaf| {
            if (d.view.zoomed and (d.view.focus == null or !eq(u8, leaf.pane, d.view.focus.?))) continue;
            const r = if (d.view.zoomed) area else leaf.rect;
            try out.append(a, .{ .pane = leaf.pane, .rect = r, .inner = shrink(r, .single), .border = .single, .float = false });
        }
    }
    for (try d.floatBoxes(a)) |b| {
        const r = b.placement.rect;
        try out.append(a, .{ .pane = b.pane.id, .rect = r, .inner = shrink(r, b.spec.border), .border = b.spec.border, .float = true, .title = b.spec.title });
    }
    return out.toOwnedSlice(a);
}

/// The topmost shown pane under a cell.
pub fn hit(shown: []const Shown, x: u16, y: u16) ?*const Shown {
    var i = shown.len;
    while (i > 0) {
        i -= 1;
        const s = &shown[i];
        if (x >= s.rect.x and x < s.rect.x + s.rect.width and y >= s.rect.y and y < s.rect.y + s.rect.height) return s;
    }
    return null;
}

pub const Streams = struct {
    ctx: *anyopaque,
    find: *const fn (ctx: *anyopaque, pane: []const u8) ?*PaneStream,
    view: *const fn (ctx: *anyopaque, pane: []const u8) ?*term.VtView,
};

fn region(r: floats.Rect) Region {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

fn levelMark(chrome: Chrome, level: shared.Level) term.theme.Mark {
    return chrome.statusMark(switch (level) {
        .none => .idle,
        .info => .info,
        .warn => .warn,
        .urgent => .danger,
    });
}

/// Draw everything. `a` is a per-frame arena.
pub fn draw(d: *Desk, a: std.mem.Allocator, surface: *Surface, chrome: Chrome, streams: Streams) !void {
    try surface.clear(.{ .width = surface.width, .height = surface.height }, .{});
    surface.setCursor(null);
    const shown = try layout(d, a);
    for (shown) |s| {
        if (s.float) try surface.clear(region(s.rect), .{});
        const focused = d.view.focus != null and eq(u8, d.view.focus.?, s.pane);
        const border_style = if (focused) chrome.focusedBorder() else chrome.inactiveBorder();
        try box(surface, s.rect, s.border, border_style);
        const stream = streams.find(streams.ctx, s.pane);
        // Pane content through venom-term: each client keeps its own view.
        if (stream) |ps| if (ps.vt) |vt| {
            if (streams.view(streams.ctx, s.pane)) |v| {
                const back = d.view.scroll.get(s.pane) orelse 0;
                if (back == 0) v.follow() else {
                    const rows = vt.rows();
                    const top = if (rows.active > rows.oldest + back) rows.active - back else rows.oldest;
                    v.scrollTo(vt, top) catch v.follow();
                }
                try v.draw(vt, surface, region(s.inner));
                if (focused and back == 0 and d.view.overlay == .none) {
                    const c = vt.cursor();
                    if (c.visible and c.x < s.inner.width and c.y < s.inner.height) surface.setCursor(.{ .x = s.inner.x + c.x, .y = s.inner.y + c.y });
                }
            }
        };
        // The title on the top border: pane ID, its OSC 2 or float title,
        // and its exit once the program is gone.
        if (s.border != .none and s.rect.width > 4) {
            var title: std.ArrayList(u8) = .empty;
            try title.print(a, " {s}", .{s.pane});
            const osc = if (stream) |ps| if (ps.vt) |vt| vt.title() catch "" else "" else "";
            const t = if (s.title.len > 0) s.title else osc;
            if (t.len > 0 and std.unicode.utf8ValidateSlice(t) and std.mem.indexOfAny(u8, t, "\r\n\x1b") == null) try title.print(a, " · {s}", .{t});
            if (stream) |ps| if (ps.exit) |e| switch (e) {
                .code => |code| try title.print(a, " [exited {d}]", .{code}),
                .signal => |sig| try title.print(a, " [{s}]", .{sig}),
            };
            try title.append(a, ' ');
            surface.text(.{ .x = s.rect.x + 1, .y = s.rect.y, .width = s.rect.width - 2, .height = 1 }, title.items, if (focused) chrome.focusedBorder() else chrome.mutedText()) catch {};
        }
        // The attention marker, glyph plus level, at the right of the
        // top edge, so it never depends on colour alone.
        if (d.state.pane(s.pane)) |p| if (p.level != .none and s.rect.width > 8) {
            const mark = levelMark(chrome, p.level);
            const text = try std.fmt.allocPrint(a, " {s} {s} ", .{ mark.glyph, @tagName(p.level) });
            const w: u16 = @intCast(@min(status.width(text), s.rect.width - 2));
            surface.text(.{ .x = s.rect.x + s.rect.width - 1 - w, .y = s.rect.y, .width = w, .height = 1 }, text, mark.style) catch {};
        };
    }
    // The rail: the status segments as rows, groups as
    // lists, on the status bar's colours with a rule before the panes.
    if (d.railRect()) |r| {
        try surface.clear(region(r), chrome.statusBar());
        const lines = try d.railLines(a);
        for (lines, 0..) |l, i| {
            if (i >= r.height) break;
            const style = if (i == 0) chrome.mutedText() else chrome.statusBar();
            surface.text(.{ .x = r.x, .y = r.y + @as(u16, @intCast(i)), .width = r.width - 1, .height = 1 }, l, style) catch {};
        }
        for (0..r.height) |i| surface.text(.{ .x = r.x + r.width - 1, .y = r.y + @as(u16, @intCast(i)), .width = 1, .height = 1 }, "│", chrome.inactiveBorder()) catch {};
    }
    if (d.statusRow()) |row| {
        const line = try d.statusLine(a);
        try surface.clear(.{ .y = row, .width = surface.width, .height = 1 }, chrome.statusBar());
        surface.text(.{ .y = row, .width = surface.width, .height = 1 }, line, chrome.statusBar()) catch {};
    }
    switch (d.view.overlay) {
        .none => {},
        .palette => {
            const pv = try d.paletteView(a);
            try popup(d, surface, chrome, pv.title, pv.lines, pv.selected);
        },
        .inbox => {
            const lines = try d.inboxLines(a);
            try popup(d, surface, chrome, "inbox", if (lines.len == 0) &.{"nothing needs you"} else lines, null);
        },
    }
    // Over everything in the pane area, changing no pane.
    if (d.popup.visible()) {
        const theme = chrome.widgets();
        _ = try term.widgets.leader_popup.draw(surface, region(d.windowArea()), &theme, try d.popupModel(a), .{});
    }
}

fn popup(d: *Desk, surface: *Surface, chrome: Chrome, title: []const u8, lines: []const []const u8, selected: ?usize) !void {
    const area = d.windowArea();
    const spec: floats.Spec = .{ .width = .{ .percent = 60 }, .height = .{ .cells = @intCast(@min(lines.len + 2, area.height)) }, .anchor = .bottom, .min_cols = 10, .min_rows = 3 };
    const r = floats.resolve(spec, area).rect;
    try surface.clear(region(r), .{});
    try box(surface, r, .rounded, chrome.focusedBorder());
    if (r.width > 4) surface.text(.{ .x = r.x + 2, .y = r.y, .width = r.width - 4, .height = 1 }, title, chrome.focusedBorder()) catch {};
    // Keep the selection in view when the list is longer than the popup.
    const rows: usize = if (r.height > 2) r.height - 2 else 0;
    var first: usize = 0;
    if (selected) |sel| if (sel >= rows and rows > 1) {
        first = sel - rows + 1;
    };
    var y: usize = 0;
    while (y < rows and first + y < lines.len) : (y += 1) {
        const i = first + y;
        var style = chrome.widgets().normal;
        if (selected != null and selected.? == i) style.reverse = true;
        surface.text(.{ .x = r.x + 2, .y = r.y + 1 + @as(u16, @intCast(y)), .width = r.width -| 4, .height = 1 }, lines[i], style) catch {};
    }
}

fn box(surface: *Surface, r: floats.Rect, border: floats.Border, style: Style) !void {
    if (r.width < 2 or r.height < 2 or border == .none) return;
    const g: [6][]const u8 = switch (border) {
        .single => .{ "┌", "┐", "└", "┘", "─", "│" },
        .rounded => .{ "╭", "╮", "╰", "╯", "─", "│" },
        .heavy => .{ "┏", "┓", "┗", "┛", "━", "┃" },
        .none => unreachable,
    };
    const right = r.x + r.width - 1;
    const bottom = r.y + r.height - 1;
    var x = r.x + 1;
    while (x < right) : (x += 1) {
        try surface.put(x, r.y, .{ .text = g[4], .style = style });
        try surface.put(x, bottom, .{ .text = g[4], .style = style });
    }
    var y = r.y + 1;
    while (y < bottom) : (y += 1) {
        try surface.put(r.x, y, .{ .text = g[5], .style = style });
        try surface.put(right, y, .{ .text = g[5], .style = style });
    }
    try surface.put(r.x, r.y, .{ .text = g[0], .style = style });
    try surface.put(right, r.y, .{ .text = g[1], .style = style });
    try surface.put(r.x, bottom, .{ .text = g[2], .style = style });
    try surface.put(right, bottom, .{ .text = g[3], .style = style });
}

// ------------------------------------------------------------- tests

const testing = std.testing;

fn noStream(_: *anyopaque, _: []const u8) ?*PaneStream {
    return null;
}
fn noView(_: *anyopaque, _: []const u8) ?*term.VtView {
    return null;
}

test "the leader popup is venom-term's widget, at the bottom of the pane area, on time" {
    const gpa = testing.allocator;
    var fake = desk_mod.client.Fake.init(gpa);
    defer fake.deinit();
    try fake.reply("keys.list",
        \\{"leader":"ctrl+a","unlock":"ctrl+alt+a","popup_delay_ms":200,"timeout_ms":0,"tables":[{"name":"venom","prefix":"v","label":"venom","layer":"product",
        \\ "groups":[{"key":"a","label":"agents"},{"key":"w","label":"workspaces"},{"key":"v","label":"splits"}],
        \\ "bindings":[{"key":"a s","label":"stop","exec":["venom"]},{"key":"w n","label":"new","exec":["venom"]},{"key":"v n","label":"new","exec":["venom"]},
        \\  {"key":"i","label":"inbox","exec":["venom"]},{"key":"s","label":"settings","exec":["venom"]},{"key":"u","label":"usage","exec":["venom"]},{"key":"d","label":"diff","exec":["venom"]}]}]}
    );
    var d = try Desk.init(gpa, fake.client(), .{ .session = "s0", .cols = 40, .rows = 10 });
    defer d.deinit();
    try d.refresh();
    var surface = try Surface.init(gpa, 40, 10);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    defer surface.deinit(&discard.writer);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: u8 = 0;
    const streams: Streams = .{ .ctx = &ctx, .find = noStream, .view = noView };
    const chrome: Chrome = .{ .theme = &term.theme.trve, .edition = .venomx, .mode = .truecolor };

    try d.press("ctrl+a");
    try d.press("v");
    try draw(&d, a, &surface, chrome, streams);
    // Inside the delay: not drawn yet.
    try testing.expectEqualStrings("", try term.widgets.text.rowText(a, &surface, 8));

    try testing.expect(try d.tick(d.now_ms + 200));
    try draw(&d, a, &surface, chrome, streams);
    // The status line is on row 9 here, so the popup ends on row 8.
    const area = d.windowArea();
    const bottom = area.y + area.height - 1;
    const want = [_][]const u8{
        "╭ venom-desk › venom ─────────╮",
        "│ a + agents      s  settings │",
        "│ w + workspaces  u  usage    │",
        "│ v + splits      d  diff     │",
        "│ i   inbox                   │",
        "╰─────────────────────────────╯",
    };
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, try term.widgets.text.rowText(a, &surface, bottom - 5 + @as(u16, @intCast(i))));

    // Gone with leader mode.
    try d.press("esc");
    try draw(&d, a, &surface, chrome, streams);
    try testing.expectEqualStrings("", try term.widgets.text.rowText(a, &surface, bottom));
}
