//! Test-only probe for test/live.py: attaches to a real venomx daemon as
//! venom-desk (headless), waits for the snapshot, optionally performs one
//! action, and prints what this client shows as one JSON object.
//!
//!   desk-probe --session s0 [--socket PATH] [--cols 80] [--rows 24]
//!              [--product EXE]... [--action focus-attention|tile-split]
//!              [--focus PANE] [--keys KEY,KEY...] [--popup-cases ARGV_JSON]
//!              [--click X,Y]
//!
//! `--keys` presses keys after the snapshot (and `--focus`) and reports the
//! leader popup's rows in leader mode, whatever its delay. `--popup-cases` runs the popup ticket
//! cases with a second presentation client on its own connection and reports each code.
//! `--click` is a left click at a cell, last (on the status
//! line or the rail it runs the segment's target as this client).
const std = @import("std");
const desk = @import("venom-desk");
const proto = @import("proto");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var session: []const u8 = "s0";
    var socket: ?[]const u8 = null;
    var cols: u16 = 80;
    var rows: u16 = 24;
    var action: ?[]const u8 = null;
    var focus: ?[]const u8 = null;
    var key_list: ?[]const u8 = null;
    var popup_argv: ?[]const u8 = null;
    var click: ?[]const u8 = null;
    var products: std.ArrayList([]const u8) = .empty;
    defer products.deinit(gpa);
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const k = argv[i];
        const v = argv[i + 1];
        if (std.mem.eql(u8, k, "--session")) session = v else if (std.mem.eql(u8, k, "--socket")) socket = v else if (std.mem.eql(u8, k, "--cols")) cols = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, k, "--rows")) rows = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, k, "--product")) try products.append(gpa, v) else if (std.mem.eql(u8, k, "--action")) action = v else if (std.mem.eql(u8, k, "--focus")) {
            focus = v;
        } else if (std.mem.eql(u8, k, "--keys")) {
            key_list = v;
        } else if (std.mem.eql(u8, k, "--popup-cases")) {
            popup_argv = v;
        } else if (std.mem.eql(u8, k, "--click")) {
            click = v;
        } else return error.BadArgs;
    }

    var wire = try desk.client.Wire.connect(gpa, .{ .socket = socket, .environ = init.minimal.environ });
    defer wire.deinit();
    var d = try desk.Desk.init(gpa, wire.asClient(), .{ .session = session, .cols = cols, .rows = rows, .nested = init.minimal.environ.getPosix("VENOMX_PANE") != null });
    defer d.deinit();
    d.clock = "--:--";
    try d.refresh();
    try wire.subscribe(&desk.desk.event_types);
    // Drain until the snapshot's checkpoint, then until 300 ms of quiet.
    var quiet_since: i64 = proto.os.nowMs();
    while (true) {
        const now = proto.os.nowMs();
        if (d.state.ready and now - quiet_since > 300) break;
        if (now - quiet_since > 10_000) return error.Timeout;
        const item = try wire.nextEvent(50) orelse continue;
        defer gpa.free(item);
        d.now_ms = now;
        try d.handleLine(item);
        quiet_since = proto.os.nowMs();
    }
    d.now_ms = proto.os.nowMs();
    if (action) |act| {
        const l = std.meta.stringToEnum(desk.keys.Local, act) orelse return error.BadArgs;
        try d.local(l);
    }
    if (focus) |f| try d.focus(f);
    if (key_list) |list| {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |k| try d.press(k);
    }
    try desk.palette.discover(&d.palette, gpa, init.io, products.items);
    if (click) |xy| {
        var parts = std.mem.splitScalar(u8, xy, ',');
        const x = try std.fmt.parseInt(u16, parts.next() orelse return error.BadArgs, 10);
        const y = try std.fmt.parseInt(u16, parts.next() orelse return error.BadArgs, 10);
        if (!try d.click(x, y)) return error.ClickMissed;
    }
    var cases: ?PopupCases = null;
    if (popup_argv) |argv_json| cases = try popupCases(gpa, init.arena.allocator(), &wire, &d, socket, init.minimal.environ, argv_json);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Seg = struct { id: []const u8, text: []const u8 };
    var segs: std.ArrayList(Seg) = .empty;
    for (try d.statusItems(a)) |it| try segs.append(a, .{ .id = it.id, .text = it.text });
    const At = struct { id: []const u8, x: u16, width: usize };
    var placed: std.ArrayList(At) = .empty;
    for (try d.statusPlaced(a)) |p| try placed.append(a, .{ .id = p.id, .x = p.x, .width = desk.status.width(p.text) });
    const Att = struct { pane: []const u8, level: []const u8 };
    var att: std.ArrayList(Att) = .empty;
    for (d.state.panes.items) |p| if (p.level != .none) try att.append(a, .{ .pane = p.id, .level = @tagName(p.level) });
    const Entry = struct { tool: []const u8, verb: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    for (d.palette.entries.items) |e| try entries.append(a, .{ .tool = e.tool, .verb = e.verb });
    const Float = struct { pane: []const u8, x: u16, y: u16, width: u16, height: u16 };
    var fl: std.ArrayList(Float) = .empty;
    for (try d.floatBoxes(a)) |b| try fl.append(a, .{ .pane = b.pane.id, .x = b.placement.rect.x, .y = b.placement.rect.y, .width = b.placement.rect.width, .height = b.placement.rect.height });
    const popup_rows: []const desk.keys.leader_popup.Row = if (d.router.pending()) (try d.popupModel(a)).rows else &.{};
    const Table = struct { name: []const u8, layer: []const u8 };
    var tables: std.ArrayList(Table) = .empty;
    for (d.keymap.tables) |t| try tables.append(a, .{ .name = t.name, .layer = @tagName(t.layer) });
    const out = .{
        .status_line = try d.statusLine(a),
        .status_row = d.statusRow(),
        .segments = segs.items,
        .placed = placed.items,
        .rail = if (d.railRect() != null) try d.railLines(a) else &.{},
        .attention = att.items,
        .floats = fl.items,
        .window = d.view.window,
        .focus = d.view.focus,
        .product_keys = d.product_keys,
        .reachable = d.palette.reachable.items,
        .palette = entries.items,
        .message = d.message.items,
        .popup_rows = popup_rows,
        .tables = tables.items,
        .leader = try desk.keys.chordText(a, d.keymap.settings.leader),
        .client = d.client_id,
        .popup_cases = cases,
    };
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try std.json.Stringify.value(out, .{}, &w.interface);
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

const PopupCases = struct {
    other_client: []const u8,
    valid: []const u8,
    /// Popups this client shows after the valid call, and the other's.
    shown_here: usize,
    shown_there: usize,
    focus_is_popup: bool,
    expired: []const u8,
};
fn code(a: std.mem.Allocator, r: desk.client.Reply) ![]const u8 {
    return switch (r) {
        .ok => "ok",
        .err => |c| try a.dupe(u8, c),
    };
}
fn drain(gpa: std.mem.Allocator, wire: *desk.client.Wire, d: *desk.Desk, ms: i64) !void {
    const until = proto.os.nowMs() + ms;
    while (proto.os.nowMs() < until) {
        const item = try wire.nextEvent(20) orelse continue;
        defer gpa.free(item);
        try d.handleLine(item);
    }
}
fn popupCount(d: *desk.Desk, a: std.mem.Allocator) !usize {
    var n: usize = 0;
    for (try d.floatBoxes(a)) |b| n += @intFromBool(b.pane.layer == .popup);
    return n;
}
/// Popup ticket cases against the live daemon: a ticket used by another client, a
/// valid ticket (the popup shows on its client only), an expired ticket.
fn popupCases(gpa: std.mem.Allocator, out: std.mem.Allocator, wire: *desk.client.Wire, d: *desk.Desk, socket: ?[]const u8, environ: std.process.Environ, argv_json: []const u8) !PopupCases {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.json.parseFromSliceLeaky([]const []const u8, a, argv_json, .{});
    // A second presentation client of the same session, on its own connection.
    var wire2 = try desk.client.Wire.connect(gpa, .{ .socket = socket, .environ = environ });
    defer wire2.deinit();
    var d2 = try desk.Desk.init(gpa, wire2.asClient(), .{ .session = d.session });
    defer d2.deinit();
    try d2.refresh();
    try wire2.subscribe(&desk.desk.event_types);
    try drain(gpa, &wire2, &d2, 300);
    _ = try d2.mintTicket(a) orelse return error.NoTicket;

    const mine = try d.mintTicket(a) orelse return error.NoTicket;
    const c = d.client;
    const other = try code(out, try wire2.asClient().call(a, "pane.popup", .{ .ticket = mine, .argv = argv }));
    const valid = try code(out, try c.call(a, "pane.popup", .{ .ticket = mine, .argv = argv, .preset = "user.pop" }));
    try drain(gpa, wire, d, 300);
    try drain(gpa, &wire2, &d2, 100);
    const here = try popupCount(d, a);
    const there = try popupCount(&d2, a);
    const focused = if (d.view.focus) |f| (if (d.state.pane(f)) |p| p.layer == .popup else false) else false;
    const late = try d.mintTicket(a) orelse return error.NoTicket;
    // Tickets live 10 s.
    try drain(gpa, wire, d, 10_200);
    const expired = try code(out, try c.call(a, "pane.popup", .{ .ticket = late, .argv = argv }));
    return .{ .other_client = other, .valid = valid, .shown_here = here, .shown_there = there, .focus_is_popup = focused, .expired = expired };
}
