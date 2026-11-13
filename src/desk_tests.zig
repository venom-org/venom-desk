//! Two presentation clients on one session: both are fed
//! the same daemon events and must show the same shared content while
//! keeping their own view. The venomx side is a `client.Fake` whose replies
//! use venomx's wire shapes (`keys.list`, floats and popups); test/live.py runs the same cases against a real daemon.
const std = @import("std");
const desk_mod = @import("desk.zig");
const Desk = desk_mod.Desk;
const Fake = @import("client.zig").Fake;
const palette = @import("palette.zig");
const keys = @import("keys.zig");
const testing = std.testing;
const eq = std.mem.eql;

const snapshot =
    \\{"type":"state.snapshot","data":{"entities":[
    \\ {"entity_type":"window","content":"{\"window\":\"w0\",\"session\":\"s0\",\"revision\":1,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p4\"}]}"},
    \\ {"entity_type":"window","content":"{\"window\":\"w1\",\"session\":\"s0\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p5\"}]}"},
    \\ {"entity_type":"pane","content":"{\"pane\":\"p0\",\"session\":\"s0\",\"tags\":[{\"key\":\"owner\",\"value\":\"venomx\"}]}"},
    \\ {"entity_type":"pane","content":"{\"pane\":\"p4\",\"session\":\"s0\",\"tags\":[{\"key\":\"owner\",\"value\":\"venom\"},{\"key\":\"role\",\"value\":\"agent\"}]}"},
    \\ {"entity_type":"pane","content":"{\"pane\":\"p5\",\"session\":\"s0\",\"tags\":[]}"},
    \\ {"entity_type":"pane","content":"{\"pane\":\"p9\",\"session\":\"s0\",\"window\":\"w0\",\"layer\":\"float\",\"preset\":\"venom.settings\",\"z\":1}"},
    \\ {"entity_type":"status","content":"{\"id\":\"user.build\",\"text\":\"build green\",\"style\":\"ok\",\"priority\":60}"}
    \\]}}
;
const checkpoint = "{\"type\":\"stream.checkpoint\",\"data\":{}}";

// The `keys.list` result shape of venomx.
const keys_list =
    \\{"leader":"ctrl+a","unlock":"ctrl+alt+a","timeout_ms":2000,"tables":[{"name":"venomx","layer":"builtin","bindings":[]},
    \\ {"name":"venom","prefix":"a","layer":"product","source":"g9","when":[{"key":"owner","value":"venom"}],
    \\  "bindings":[{"key":"a","exec":["venom","approve","--pane","{pane}"]},
    \\   {"key":"n","exec":["venom","thread","pick","--ticket","{popup_ticket}"]},
    \\   {"key":"s","verb":"pane.popup","args":"{\"preset\":\"venom.settings\",\"argv\":[\"venom\",\"settings\"]}"}]}]}
;

const Pair = struct {
    fake_a: Fake,
    fake_b: Fake,
    a: Desk,
    b: Desk,
    fn deinit(self: *Pair) void {
        self.a.deinit();
        self.b.deinit();
        self.fake_a.deinit();
        self.fake_b.deinit();
    }
    fn both(self: *Pair, line: []const u8) !void {
        try self.a.handleLine(line);
        try self.b.handleLine(line);
    }
};

/// The popup's row for `key`, whether or not its delay has passed.
fn popupRow(d: *const Desk, a: std.mem.Allocator, key: []const u8) !?keys.leader_popup.Row {
    for ((try d.popupModel(a)).rows) |row| if (eq(u8, row.keys, key)) return row;
    return null;
}

fn pair(p: *Pair, a_cols: u16, b_cols: u16) !void {
    const gpa = testing.allocator;
    p.fake_a = Fake.init(gpa);
    p.fake_b = Fake.init(gpa);
    try p.fake_a.reply("keys.list", keys_list);
    try p.fake_b.reply("keys.list", keys_list);
    try p.fake_a.reply("config.get", "{\"key\":\"status\",\"content\":\".{}\"}");
    try p.fake_b.reply("config.get", "{\"key\":\"status\",\"content\":\".{}\"}");
    p.a = try Desk.init(gpa, p.fake_a.client(), .{ .session = "s0", .cols = a_cols, .rows = 24 });
    p.b = try Desk.init(gpa, p.fake_b.client(), .{ .session = "s0", .cols = b_cols, .rows = 30 });
    p.a.clock = "14:02";
    p.b.clock = "14:02";
    try p.a.refresh();
    try p.b.refresh();
    try p.a.presets.put("venom.settings", .product, .{ .width = .{ .percent = 80 }, .height = .{ .percent = 80 }, .title = "venom settings" });
    try p.b.presets.put("venom.settings", .product, .{ .width = .{ .percent = 80 }, .height = .{ .percent = 80 }, .title = "venom settings" });
    try p.both(snapshot);
    try p.both(checkpoint);
}

fn segmentIds(d: *Desk, a: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try d.statusItems(a)) |i| if (!eq(u8, i.id, "venomx.pane") and !eq(u8, i.id, "venomx.windows")) try out.append(a, i.id);
    return out.toOwnedSlice(a);
}

test "two clients show the same segments, attention and floats with their own view" {
    var p: Pair = undefined;
    try pair(&p, 120, 80);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both pick the lowest window and its first pane by themselves.
    try testing.expectEqualStrings("w0", p.a.view.window.?);
    try testing.expectEqualStrings("p0", p.b.view.focus.?);

    // A product publishes a segment and sets attention on p4.
    try p.both("{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom-os.agents\",\"text\":\"2 running · 1 waiting\",\"style\":\"warn\",\"priority\":50}}}");
    try p.both("{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p4\",\"level\":\"urgent\",\"reason\":\"approval: rm -rf build/\"}}");

    // Client B looks at another window and zooms: its own view only.
    try p.b.local(.@"window-next");
    try testing.expectEqualStrings("w1", p.b.view.window.?);
    try p.b.local(.zoom);
    try testing.expect(p.b.view.zoomed and !p.a.view.zoomed);
    try testing.expectEqualStrings("w0", p.a.view.window.?);
    // No view change sent anything to the daemon.
    for (p.fake_b.calls.items) |c| try testing.expect(eq(u8, c.verb, "keys.list") or eq(u8, c.verb, "config.get"));

    // Same shared content on both, regardless of view and width.
    const ids_a = try segmentIds(&p.a, a);
    const ids_b = try segmentIds(&p.b, a);
    try testing.expectEqual(ids_a.len, ids_b.len);
    for (ids_a, ids_b) |x, y| try testing.expectEqualStrings(x, y);
    const line_a = try p.a.statusLine(a);
    const line_b = try p.b.statusLine(a);
    for ([_][]const u8{ "▲ 2 running · 1 waiting", "▲ 1 attention", "● build green", " s0 " }) |want| {
        try testing.expect(std.mem.indexOf(u8, line_a, want) != null);
        try testing.expect(std.mem.indexOf(u8, line_b, want) != null);
    }
    try testing.expect(std.mem.indexOf(u8, line_a, "▸1 2") != null);
    try testing.expect(std.mem.indexOf(u8, line_b, "1 ▸2") != null);
    // Default config: the status line is the top row.
    const frame_a = try p.a.frame(a);
    try testing.expectEqualStrings(line_a, frame_a[0]);
    // The attention marker on p4's edge, and the float from its preset.
    var marker = false;
    var float_title = false;
    for (frame_a) |row| {
        marker = marker or std.mem.indexOf(u8, row, "✕ urgent") != null;
        float_title = float_title or std.mem.indexOf(u8, row, "venom settings") != null;
    }
    try testing.expect(marker and float_title);
    const boxes_a = try p.a.floatBoxes(a);
    try testing.expectEqual(@as(usize, 1), boxes_a.len);
    try testing.expectEqual(@as(u16, 96), boxes_a[0].placement.rect.width);
    try testing.expect(boxes_a[0].known_preset);
    // B shows w1, which has no floats.
    try testing.expectEqual(@as(usize, 0), (try p.b.floatBoxes(a)).len);

    // A narrow client drops low priorities first.
    p.b.options.cols = 40;
    const narrow = try p.b.statusLine(a);
    try testing.expect(std.mem.indexOf(u8, narrow, "14:02") == null);
    try testing.expect(std.mem.indexOf(u8, narrow, " s0 ") != null);

    // A focuses p4; it clears attention under its own identity.
    try p.a.local(.@"focus-attention");
    try testing.expectEqualStrings("p4", p.a.view.focus.?);
    const clear = p.fake_a.last("pane.attention").?;
    try testing.expectEqualStrings("{\"pane\":\"p4\",\"clear\":true}", clear.params);
    try testing.expectEqual(@as(usize, 0), p.fake_b.count("pane.attention"));
    // The daemon's event reaches both clients; the marker goes everywhere.
    try p.both("{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p4\",\"level\":\"none\",\"reason\":\"\"}}");
    try testing.expect(std.mem.indexOf(u8, try p.b.statusLine(a), "attention") == null);
    // The segment's connection closed: gone from both.
    try p.both("{\"type\":\"status.cleared\",\"data\":{\"id\":\"venom-os.agents\",\"reason\":\"disconnect\"}}");
    try testing.expect(std.mem.indexOf(u8, try p.a.statusLine(a), "running") == null);
}

test "sticky attention is not cleared on focus" {
    var p: Pair = undefined;
    try pair(&p, 80, 80);
    defer p.deinit();
    p.a.attention_config.sticky = true;
    try p.both("{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p4\",\"level\":\"warn\",\"reason\":\"\"}}");
    try p.a.focus("p4");
    try testing.expectEqual(@as(usize, 0), p.fake_a.count("pane.attention"));
}

const Recorder = struct {
    argv: std.ArrayList([]u8) = .empty,
    token_seen: bool = false,
    env_len: usize = 0,
    fn run(ctx: ?*anyopaque, argv: []const []const u8, env: []const []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        for (argv) |x| self.argv.append(testing.allocator, testing.allocator.dupe(u8, x) catch unreachable) catch unreachable;
        self.env_len = env.len;
        for (env) |e| self.token_seen = self.token_seen or std.mem.startsWith(u8, e, "VENOMX_TOKEN=") or
            std.mem.startsWith(u8, e, "VENOMX_PRINCIPAL=") or std.mem.indexOf(u8, e, "vnt1.") != null;
    }
    fn deinit(self: *Recorder) void {
        for (self.argv.items) |x| testing.allocator.free(x);
        self.argv.deinit(testing.allocator);
    }
};

test "leader, popup rows, product table on a tagged pane, exec without a token" {
    var p: Pair = undefined;
    try pair(&p, 100, 80);
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    p.a.options.exec = Recorder.run;
    p.a.options.exec_ctx = &rec;
    p.a.options.environ = &.{ "HOME=/h", "VENOMX_TOKEN=vnt1.venomx.g1.secret", "VENOMX_PRINCIPAL=g1", "NOTE=vnt1.venomx.g1.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(p.a.product_keys);

    // ctrl+b and shift+tab reach the focused agent unchanged.
    try p.a.press("ctrl+b");
    try p.a.press("shift+tab");
    try testing.expectEqual(@as(usize, 2), p.a.forwarded.items.len);
    try testing.expectEqualStrings("ctrl+b", p.a.forwarded.items[0]);

    // On p0 (owner venomx) the venom table is not offered.
    try p.a.press("ctrl+a");
    try testing.expect(p.a.router.pending());
    try testing.expect(try popupRow(&p.a, a, "a") == null);
    try testing.expect(std.mem.indexOf(u8, (try p.a.statusLine(a)), " LEADER ") != null);
    try p.a.press("esc");
    try testing.expect(!p.a.router.pending());

    try p.a.focus("p4");
    try p.a.press("ctrl+a");
    const row = (try popupRow(&p.a, a, "a")).?;
    try testing.expectEqualStrings("venom", row.label);
    try testing.expect(row.more);
    try p.a.press("a");
    try testing.expectEqualStrings("LEADER venom", try p.a.modeText(a));
    try p.a.press("a");
    try testing.expectEqual(@as(usize, 4), rec.argv.items.len);
    try testing.expectEqualStrings("venom", rec.argv.items[0]);
    try testing.expectEqualStrings("p4", rec.argv.items[3]);
    try testing.expect(!rec.token_seen);
    try testing.expectEqual(@as(usize, 1), rec.env_len);
    // Nothing more reached the pane while the leader was active.
    try testing.expectEqual(@as(usize, 2), p.a.forwarded.items.len);

    // Leader twice sends the leader itself.
    try p.a.press("ctrl+a");
    try p.a.press("ctrl+a");
    try testing.expectEqualStrings("ctrl+a", p.a.forwarded.items[2]);
}

test "without venomx keys.* only the built-in table is active" {
    const gpa = testing.allocator;
    var fake = Fake.init(gpa);
    defer fake.deinit();
    fake.missing = &.{"keys.list"};
    var d = try Desk.init(gpa, fake.client(), .{ .session = "s0" });
    defer d.deinit();
    try d.refresh();
    try testing.expect(!d.product_keys);
    try d.handleLine(snapshot);
    try d.handleLine(checkpoint);
    try d.focus("p4");
    try d.press("ctrl+a");
    try d.press("a");
    try testing.expectEqual(@as(usize, 0), d.forwarded.items.len);
    try testing.expectEqualStrings("", try d.modeText(testing.allocator));
    // keys.changed refetches the table list.
    try d.handleLine("{\"type\":\"keys.changed\",\"data\":{\"layer\":\"product\",\"table\":\"venom\",\"revision\":1}}");
    try testing.expectEqual(@as(usize, 2), fake.count("keys.list"));
}

test "floats are per client: toggle, cycle focus, presets resolve on each size" {
    var p: Pair = undefined;
    try pair(&p, 100, 60);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wa = (try p.a.floatBoxes(a))[0].placement.rect;
    const wb = (try p.b.floatBoxes(a))[0].placement.rect;
    // Same spec, each client's own rectangle (80% of its area).
    try testing.expectEqual(@as(u16, 80), wa.width);
    try testing.expectEqual(@as(u16, 48), wb.width);
    try p.a.local(.@"cycle-floats");
    try testing.expectEqualStrings("p9", p.a.view.focus.?);
    try p.a.local(.@"toggle-floats");
    try testing.expectEqual(@as(usize, 0), (try p.a.floatBoxes(a)).len);
    try testing.expectEqualStrings("p0", p.a.view.focus.?);
    try testing.expectEqual(@as(usize, 1), (try p.b.floatBoxes(a)).len);
    // A shared geometry change (pane.placed) reaches both.
    try p.both("{\"type\":\"pane.placed\",\"data\":{\"pane\":\"p9\",\"layer\":\"float\",\"window\":\"w0\",\"preset\":\"venom.settings\",\"float\":{\"preset\":\"venom.settings\",\"width\":\"50%\"}}}");
    try testing.expectEqual(@as(u16, 30), (try p.b.floatBoxes(a))[0].placement.rect.width);
    // Unknown presets fall back to floats.default and are flagged.
    try p.both("{\"type\":\"pane.placed\",\"data\":{\"pane\":\"p9\",\"layer\":\"float\",\"window\":\"w0\",\"preset\":\"venom.nope\"}}");
    const box = (try p.b.floatBoxes(a))[0];
    try testing.expect(!box.known_preset);
    try testing.expectEqual(@as(u16, 36), box.placement.rect.width);
}

test "tiling policy drives pane.split with workspace tags; pane.place requests" {
    var p: Pair = undefined;
    try pair(&p, 160, 41);
    defer p.deinit();
    p.a.options.policy = .@"master-stack";
    try p.a.local(.@"tile-split");
    const split = p.fake_a.last("pane.split").?;
    try testing.expect(std.mem.indexOf(u8, split.params, "\"pane\":\"p4\"") != null);
    try testing.expect(std.mem.indexOf(u8, split.params, "\"axis\":\"rows\"") != null);
    try testing.expect(std.mem.indexOf(u8, split.params, "\"tags\":[{\"key\":\"workspace\",\"value\":\"s0\"}]") != null);
    try p.a.local(.@"split-right");
    try testing.expect(std.mem.indexOf(u8, p.fake_a.last("pane.split").?.params, "\"pane\":\"p0\",\"axis\":\"cols\"") != null);
    try p.a.placeTiled("p9");
    try testing.expect(std.mem.indexOf(u8, p.fake_a.last("pane.place").?.params, "\"tile\":{\"target\":\"p4\",\"axis\":\"rows\"}") != null);
    try p.a.placeFloat("p0", "venom.diff");
    try testing.expectEqualStrings("{\"pane\":\"p0\",\"float\":{\"preset\":\"venom.diff\"}}", p.fake_a.last("pane.place").?.params);
}

test "workspaces are tagged venomx sessions" {
    const gpa = testing.allocator;
    var fake = Fake.init(gpa);
    defer fake.deinit();
    try fake.reply("session.create", "{\"session\":\"s3\",\"name\":\"docs\"}");
    try fake.reply("session.list", "{\"sessions\":[{\"session\":\"s0\",\"name\":\"work\"},{\"session\":\"s3\",\"name\":\"docs\"}]}");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const s = try desk_mod.createWorkspace(arena.allocator(), fake.client(), "docs", &.{"/bin/sh"});
    try testing.expectEqualStrings("s3", s);
    try testing.expect(std.mem.indexOf(u8, fake.last("window.create").?.params, "\"tags\":[{\"key\":\"workspace\",\"value\":\"docs\"}]") != null);
    const list = try desk_mod.listWorkspaces(arena.allocator(), fake.client());
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("docs", list[1].name);
}

test "palette lists venomx and venom verbs; entries run through the right channel" {
    var p: Pair = undefined;
    try pair(&p, 100, 80);
    defer p.deinit();
    try p.a.palette.addMcpOutput("venomx", palette.venomx_fixture);
    try p.a.palette.addMcpOutput("venom", palette.venom_fixture);
    var rec: Recorder = .{};
    defer rec.deinit();
    p.a.options.exec = Recorder.run;
    p.a.options.exec_ctx = &rec;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try p.a.local(.palette);
    var rows_have = [2]bool{ false, false };
    for (try p.a.paletteLines(a, "")) |l| {
        rows_have[0] = rows_have[0] or std.mem.startsWith(u8, l, "venomx pane split");
        rows_have[1] = rows_have[1] or std.mem.startsWith(u8, l, "venom thread pick");
    }
    try testing.expect(rows_have[0] and rows_have[1]);
    const split = (try p.a.palette.filter(a, "venomx split"))[0].entry;
    try p.a.runEntry(split, "{\"pane\":\"p0\",\"axis\":\"rows\",\"argv\":[\"/bin/sh\"]}");
    try testing.expectEqualStrings("{\"pane\":\"p0\",\"axis\":\"rows\",\"argv\":[\"/bin/sh\"]}", p.fake_a.last("pane.split").?.params);
    const approve = (try p.a.palette.filter(a, "venom approve"))[0].entry;
    try p.a.runEntry(approve, "{\"pane\":\"p4\"}");
    const want = [_][]const u8{ "venom", "approve", "--pane=p4", "--json" };
    try testing.expectEqual(want.len, rec.argv.items.len);
    for (want, rec.argv.items) |w, got| try testing.expectEqualStrings(w, got);
    const zoom = (try p.a.palette.filter(a, "desk zoom"))[0].entry;
    try p.a.runEntry(zoom, "{}");
    try testing.expect(p.a.view.zoomed);
}

test "notifications: status line shows the newest, the inbox keeps history" {
    var p: Pair = undefined;
    try pair(&p, 100, 80);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    p.a.now_ms = 1000;
    try p.a.handleLine("{\"type\":\"notify.posted\",\"data\":{\"id\":\"n1\",\"text\":\"thread-7 finished\",\"level\":\"info\",\"ttl_ms\":8000}}");
    try testing.expect(std.mem.indexOf(u8, try p.a.statusLine(a), "◆ thread-7 finished") != null);
    _ = try p.a.tick(10_000);
    try testing.expect(std.mem.indexOf(u8, try p.a.statusLine(a), "thread-7") == null);
    try testing.expectEqual(@as(usize, 1), p.a.history.unread());
    try p.a.handleLine("{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p4\",\"level\":\"urgent\",\"reason\":\"approval\"}}");
    try p.a.local(.inbox);
    const lines = try p.a.inboxLines(a);
    try testing.expectEqualStrings("✕ p4 approval", lines[0]);
    try testing.expectEqualStrings("◆ thread-7 finished", lines[1]);
    try testing.expectEqual(@as(usize, 0), p.a.history.unread());
}

test "nested clients say so; status position comes from config" {
    const gpa = testing.allocator;
    var fake = Fake.init(gpa);
    defer fake.deinit();
    try fake.reply("config.get", "{\"key\":\"status\",\"content\":\".{ .position = .bottom }\"}");
    var d = try Desk.init(gpa, fake.client(), .{ .session = "s0", .nested = true, .cols = 60, .rows = 10 });
    defer d.deinit();
    try d.refresh();
    try d.handleLine(snapshot);
    try d.handleLine(checkpoint);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try d.frame(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, rows[9], "NESTED") != null);
    try testing.expectEqual(@as(?u16, 9), d.statusRow());
    try d.handleLine("{\"type\":\"session.removed\",\"data\":{\"session\":\"s0\"}}");
    try testing.expect(d.ended);
}

test "keys names used by built-ins are canonical" {
    var m = try keys.Keymap.init(testing.allocator, .{});
    defer m.deinit();
    const leader = try keys.chordText(testing.allocator, m.settings.leader);
    defer testing.allocator.free(leader);
    try testing.expectEqualStrings("ctrl+a", leader);
    try testing.expectEqualStrings("venom-desk", m.tables[0].name);
}

test "palette input: typed query, highlight, prompts for required params, then the verb" {
    var p: Pair = undefined;
    try pair(&p, 100, 80);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try p.both(snapshot);
    try p.both(checkpoint);
    try p.a.palette.addMcpOutput("venomx", palette.venomx_fixture);
    try p.a.press("ctrl+a");
    try p.a.press(":");
    try testing.expectEqual(desk_mod.Overlay.palette, p.a.view.overlay);
    for ([_][]const u8{ "s", "t", "a", "t", "u", "s", "space", "s", "e", "t" }) |k| try p.a.press(k);
    var view = try p.a.paletteView(a);
    try testing.expectEqualStrings("> status set_", view.lines[0]);
    try testing.expect(std.mem.startsWith(u8, view.lines[1], "venomx status set"));
    try testing.expectEqual(@as(?usize, 1), view.selected);
    // Every key stays in the palette: nothing reached a pane.
    try testing.expectEqual(@as(usize, 0), p.a.forwarded.items.len);
    try p.a.press("enter");
    view = try p.a.paletteView(a);
    try testing.expectEqualStrings("id: _", view.lines[1]);
    for ([_][]const u8{ "u", "s", "e", "r", ".", "x" }) |k| try p.a.press(k);
    try p.a.press("enter");
    try p.a.press("h");
    try p.a.press("i");
    try p.a.press("backspace");
    try p.a.press("enter");
    try testing.expectEqual(desk_mod.Overlay.none, p.a.view.overlay);
    try testing.expectEqualStrings("{\"id\":\"user.x\",\"text\":\"h\"}", p.fake_a.last("status.set").?.params);
    // The other client saw none of it.
    try testing.expect(p.fake_b.last("status.set") == null);
    // Escape closes without running anything.
    try p.a.local(.palette);
    try p.a.press("x");
    try p.a.press("escape");
    try testing.expectEqual(desk_mod.Overlay.none, p.a.view.overlay);
    try testing.expectEqual(@as(usize, 1), p.fake_a.count("status.set"));
}

test "a failed exec is a notice for this client only" {
    var p: Pair = undefined;
    try pair(&p, 100, 80);
    defer p.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try p.both(snapshot);
    try p.both(checkpoint);
    try p.a.notice(.warn, "exec {s} exited {d}", .{ "venom", 3 });
    try testing.expectEqualStrings("exec venom exited 3", p.a.message.items);
    var found = false;
    for (try p.a.inboxLines(a)) |l| found = found or std.mem.indexOf(u8, l, "exec venom exited 3") != null;
    try testing.expect(found);
    for (try p.b.inboxLines(a)) |l| try testing.expect(std.mem.indexOf(u8, l, "exec venom") == null);
    // Nothing was posted to the daemon.
    try testing.expect(p.fake_a.last("notify.post") == null);
}

test "popup tickets: minted per binding, popups only on the ticket's client, focus and dismiss" {
    var p: Pair = undefined;
    try pair(&p, 100, 80);
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    p.a.options.exec = Recorder.run;
    p.a.options.exec_ctx = &rec;
    try p.fake_a.reply("popup.ticket", "{\"ticket\":\"0123456789abcdef0123456789abcdef\",\"client\":\"c0\",\"session\":\"s0\",\"window\":\"w0\",\"ttl_ms\":10000}");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An exec binding with {popup_ticket}: one ticket, a whole argv element.
    try p.a.focus("p4");
    for ([_][]const u8{ "ctrl+a", "a", "n" }) |k| try p.a.press(k);
    try testing.expectEqual(@as(usize, 1), p.fake_a.count("popup.ticket"));
    try testing.expectEqualStrings("{\"session\":\"s0\",\"window\":\"w0\"}", p.fake_a.last("popup.ticket").?.params);
    try testing.expectEqual(@as(usize, 5), rec.argv.items.len);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", rec.argv.items[4]);
    try testing.expectEqualStrings("c0", p.a.client_id.?);
    // Bindings without the placeholder mint nothing.
    for ([_][]const u8{ "ctrl+a", "a", "a" }) |k| try p.a.press(k);
    try testing.expectEqual(@as(usize, 1), p.fake_a.count("popup.ticket"));

    // The client's own pane.popup binding mints and passes a ticket itself.
    for ([_][]const u8{ "ctrl+a", "a", "s" }) |k| try p.a.press(k);
    try testing.expectEqual(@as(usize, 2), p.fake_a.count("popup.ticket"));
    const popup = p.fake_a.last("pane.popup").?.params;
    try testing.expect(std.mem.indexOf(u8, popup, "\"ticket\":\"0123456789abcdef0123456789abcdef\"") != null);
    try testing.expect(std.mem.indexOf(u8, popup, "\"preset\":\"venom.settings\"") != null);

    // venomx opens it for client c0: only that client shows it, and it takes
    // that client's focus. The other client's view does not change.
    const b_focus = try a.dupe(u8, p.b.view.focus.?);
    try p.both("{\"type\":\"pane.created\",\"data\":{\"pane\":\"p20\",\"session\":\"s0\",\"window\":\"w0\",\"layer\":\"popup\",\"client\":\"c0\",\"float\":{\"preset\":\"venom.settings\",\"width\":\"80%\",\"height\":\"80%\",\"anchor\":\"center\",\"border\":\"rounded\",\"min_cols\":20,\"min_rows\":5,\"z\":3}}}");
    const boxes = try p.a.floatBoxes(a);
    try testing.expectEqual(@as(usize, 2), boxes.len);
    try testing.expectEqualStrings("p20", boxes[1].pane.id);
    try testing.expectEqualStrings("p20", p.a.view.focus.?);
    try testing.expectEqual(@as(usize, 1), (try p.b.floatBoxes(a)).len);
    try testing.expectEqualStrings(b_focus, p.b.view.focus.?);
    // Hiding the float layer keeps the popup.
    try p.a.local(.@"toggle-floats");
    try testing.expectEqual(@as(usize, 1), (try p.a.floatBoxes(a)).len);
    try testing.expectEqualStrings("p20", p.a.view.focus.?);

    // dismiss-popup removes it in venomx; on pane.removed focus goes back.
    try p.a.local(.@"dismiss-popup");
    try testing.expectEqualStrings("{\"pane\":\"p20\",\"remove\":true}", p.fake_a.last("pane.kill").?.params);
    try p.both("{\"type\":\"pane.removed\",\"data\":{\"pane\":\"p20\",\"session\":\"s0\"}}");
    try testing.expectEqualStrings("p4", p.a.view.focus.?);

    // venomx refusals reach the message line.
    p.fake_a.failing = &.{.{ "pane.popup", "denied.popup_ticket" }};
    for ([_][]const u8{ "ctrl+a", "a", "s" }) |k| try p.a.press(k);
    try testing.expect(std.mem.indexOf(u8, p.a.message.items, "popup ticket refused") != null);
    p.fake_a.failing = &.{.{ "popup.ticket", "not_found.session" }};
    const before = p.fake_a.count("pane.popup");
    for ([_][]const u8{ "ctrl+a", "a", "s" }) |k| try p.a.press(k);
    try testing.expectEqual(before, p.fake_a.count("pane.popup"));
    try testing.expectEqualStrings("popup.ticket: not_found.session", p.a.message.items);
}

test "a popup closing during leader mode hands the sequence to the pane focus returns to" {
    var p: Pair = undefined;
    try pair(&p, 100, 80);
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    p.a.options.exec = Recorder.run;
    p.a.options.exec_ctx = &rec;
    try p.fake_a.reply("popup.ticket", "{\"ticket\":\"0123456789abcdef0123456789abcdef\",\"client\":\"c0\",\"session\":\"s0\",\"window\":\"w0\",\"ttl_ms\":10000}");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The ticket's reply names this client, so the popup is its own.
    try p.a.focus("p4");
    for ([_][]const u8{ "ctrl+a", "a", "n" }) |k| try p.a.press(k);
    try testing.expectEqual(@as(usize, 5), rec.argv.items.len);
    try p.both("{\"type\":\"pane.created\",\"data\":{\"pane\":\"p20\",\"session\":\"s0\",\"window\":\"w0\",\"layer\":\"popup\",\"client\":\"c0\",\"float\":{\"preset\":\"venom.settings\",\"width\":\"80%\",\"height\":\"80%\",\"anchor\":\"center\",\"border\":\"rounded\",\"min_cols\":20,\"min_rows\":5,\"z\":3}}}");
    try testing.expectEqualStrings("p20", p.a.view.focus.?);

    // The leader arrives while the popup still has the focus.
    try p.a.press("ctrl+a");
    try testing.expect(try popupRow(&p.a, a, "a") == null);
    // It closes: the rows and the next keys are p4's.
    try p.both("{\"type\":\"pane.removed\",\"data\":{\"pane\":\"p20\",\"session\":\"s0\"}}");
    try testing.expectEqualStrings("p4", p.a.view.focus.?);
    try testing.expect(p.a.router.pending());
    try testing.expect(try popupRow(&p.a, a, "a") != null);
    try p.a.press("a");
    try testing.expectEqualStrings("LEADER venom", try p.a.modeText(a));
    const ran = rec.argv.items.len;
    try p.a.press("a");
    try testing.expectEqualStrings("venom", rec.argv.items[ran]);
    try testing.expectEqualStrings("p4", rec.argv.items[ran + 3]);
    try testing.expect(!p.a.router.pending());

    // Inside the table, a move to a pane without it ends leader mode, the popup
    // goes, and the next key is the pane's.
    const forwarded = p.a.forwarded.items.len;
    for ([_][]const u8{ "ctrl+a", "a" }) |k| try p.a.press(k);
    p.a.now_ms += 1000;
    _ = try p.a.tick(p.a.now_ms);
    try testing.expect(p.a.popup.visible());
    try testing.expect((try p.a.popupModel(a)).rows.len > 0);
    try p.a.focus("p0");
    try testing.expect(!p.a.router.pending());
    try testing.expect(!p.a.popup.visible());
    try p.a.press("s");
    try testing.expectEqual(forwarded + 1, p.a.forwarded.items.len);
    try testing.expectEqualStrings("s", p.a.forwarded.items[forwarded]);
}

test "keys.list settings: the daemon's leader replaces the default" {
    const gpa = testing.allocator;
    var fake = Fake.init(gpa);
    defer fake.deinit();
    try fake.reply("keys.list", "{\"leader\":\"ctrl+b\",\"unlock\":\"ctrl+alt+a\",\"timeout_ms\":2000,\"tables\":[]}");
    var d = try Desk.init(gpa, fake.client(), .{ .session = "s0" });
    defer d.deinit();
    try d.refresh();
    try d.handleLine(snapshot);
    try d.handleLine(checkpoint);
    try d.press("ctrl+a");
    try testing.expectEqualStrings("ctrl+a", d.forwarded.items[0]);
    try d.press("ctrl+b");
    try testing.expect(d.router.pending());
}

// An example key table, as `keys.list` reports it.
const example_keys_list =
    \\{"leader":"ctrl+a","unlock":"ctrl+alt+a","popup_delay_ms":200,"timeout_ms":0,"tables":[{"name":"venom","prefix":"v","label":"venom","layer":"product",
    \\ "groups":[{"key":"a","label":"agents"},{"key":"w","label":"workspaces"},{"key":"v","label":"splits"}],
    \\ "bindings":[{"key":"a s","label":"stop","exec":["venom"]},{"key":"w n","label":"new","exec":["venom"]},{"key":"v n","label":"new","exec":["venom"]},
    \\  {"key":"i","label":"inbox","exec":["venom"]},{"key":"s","label":"settings","exec":["venom"]},{"key":"u","label":"usage","exec":["venom"]},{"key":"d","label":"diff","exec":["venom"]}]}]}
;

const Listed = struct {
    fake: Fake,
    d: Desk,
    fn init(self: *Listed, list: []const u8) !void {
        self.fake = Fake.init(testing.allocator);
        try self.fake.reply("keys.list", list);
        self.d = try Desk.init(testing.allocator, self.fake.client(), .{ .session = "s0" });
        try self.d.refresh();
    }
    /// What the next `keys.list` answers.
    fn relist(self: *Listed, list: []const u8) void {
        self.fake.replies.items[0].json = list;
    }
    fn deinit(self: *Listed) void {
        self.d.deinit();
        self.fake.deinit();
    }
};

test "the popup's rows and header are the shared model's, for keys.list's tables" {
    var l: Listed = undefined;
    try l.init(example_keys_list);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try l.d.press("ctrl+a");
    const root = try l.d.popupModel(a);
    try testing.expectEqualStrings("venom-desk", root.title);
    const venom = root.rows[0];
    try testing.expectEqualStrings("v", venom.keys);
    try testing.expect(venom.more);
    try testing.expectEqualStrings("venom", venom.label);
    // After the tables' rows, what the leader itself does.
    const last = root.rows[root.rows.len - 1];
    try testing.expectEqualStrings("ctrl+a", last.keys);
    try testing.expectEqualStrings("send-leader", last.label);

    try l.d.press("v");
    const m = try l.d.popupModel(a);
    try testing.expectEqualStrings("venom-desk › venom", m.title);
    const want = [_]keys.leader_popup.Row{
        .{ .keys = "a", .more = true, .label = "agents" },
        .{ .keys = "w", .more = true, .label = "workspaces" },
        .{ .keys = "v", .more = true, .label = "splits" },
        .{ .keys = "i", .label = "inbox" },
        .{ .keys = "s", .label = "settings" },
        .{ .keys = "u", .label = "usage" },
        .{ .keys = "d", .label = "diff" },
    };
    try testing.expectEqual(want.len, m.rows.len);
    for (want, m.rows) |w, got| {
        try testing.expectEqualStrings(w.keys, got.keys);
        try testing.expectEqualStrings(w.label, got.label);
        try testing.expectEqual(w.more, got.more);
    }
    try l.d.press("a");
    try testing.expectEqualStrings("venom-desk › venom › agents", (try l.d.popupModel(a)).title);
}

test "the popup waits keys.popup_delay_ms, a faster key skips it, and no timeout ends leader mode" {
    var l: Listed = undefined;
    try l.init(example_keys_list);
    defer l.deinit();
    const d = &l.d;
    d.now_ms = 1000;
    try d.press("ctrl+a");
    try testing.expect(!d.popup.visible());
    try testing.expectEqual(@as(?i64, 1200), d.nextWake());
    try testing.expect(!try d.tick(1199));
    try testing.expect(!d.popup.visible());
    try testing.expect(try d.tick(1200));
    try testing.expect(d.popup.visible());
    // `timeout_ms = 0`: open, with nothing to wake for, until the next key.
    try testing.expectEqual(@as(?i64, null), d.nextWake());
    try testing.expect(!try d.tick(1_000_000));
    try testing.expect(d.router.pending());
    try testing.expect(d.popup.visible());
    try d.press("esc");
    try testing.expect(!d.popup.visible());
    // A binding before the delay: it never came up.
    d.now_ms = 2_000_000;
    try d.press("ctrl+a");
    d.now_ms += 100;
    try d.press("v");
    d.now_ms += 100;
    try d.press("s");
    try testing.expect(!d.router.pending());
    try testing.expect(!try d.tick(d.now_ms + 1000));
    try testing.expect(!d.popup.visible());
}

test "a non-zero timeout ends leader mode and takes the popup down; 0 delay shows it at once" {
    var l: Listed = undefined;
    try l.init("{\"leader\":\"ctrl+a\",\"unlock\":\"ctrl+alt+a\",\"popup_delay_ms\":0,\"timeout_ms\":500,\"tables\":[]}");
    defer l.deinit();
    const d = &l.d;
    d.now_ms = 100;
    try d.press("ctrl+a");
    try testing.expect(d.popup.visible());
    try testing.expectEqual(@as(?i64, 600), d.nextWake());
    try testing.expect(try d.tick(600));
    try testing.expect(!d.router.pending());
    try testing.expect(!d.popup.visible());
}

test "leader ? shows the popup at once, and its keys work; a sticky group hides it until ?" {
    var l: Listed = undefined;
    try l.init(
        \\{"leader":"ctrl+a","unlock":"ctrl+alt+a","popup_delay_ms":200,"timeout_ms":0,"tables":[{"name":"user","prefix":"m","layer":"user",
        \\ "groups":[{"key":"r","label":"resize","sticky":true}],"bindings":[{"key":"r j","label":"down","exec":["true"]}]}]}
    );
    defer l.deinit();
    const d = &l.d;
    var rec: Recorder = .{};
    defer rec.deinit();
    d.options.exec = Recorder.run;
    d.options.exec_ctx = &rec;
    try d.press("ctrl+a");
    try d.press("?");
    try testing.expect(d.router.pending());
    try testing.expect(d.popup.visible());
    try d.press("m");
    try d.press("r");
    try testing.expect(d.popup.visible());
    try d.press("j");
    try testing.expectEqual(@as(usize, 1), rec.argv.items.len);
    try testing.expect(d.router.pending());
    try testing.expect(!d.popup.visible());
    try d.press("?");
    try testing.expect(d.popup.visible());
    try d.press("esc");
    try testing.expect(!d.router.pending());
    try testing.expect(!d.popup.visible());
}

test "a changed keys.leader applies: the keys and the popup's row follow keys.list" {
    var l: Listed = undefined;
    try l.init(example_keys_list);
    defer l.deinit();
    const d = &l.d;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try d.press("ctrl+b");
    try testing.expectEqualStrings("ctrl+b", d.forwarded.items[0]);

    l.relist("{\"leader\":\"ctrl+b\",\"unlock\":\"ctrl+alt+b\",\"popup_delay_ms\":0,\"timeout_ms\":0,\"tables\":[]}");
    try d.handleLine("{\"type\":\"config.changed\",\"data\":{\"key\":\"keys.leader\"}}");
    try d.press("ctrl+a");
    try testing.expectEqualStrings("ctrl+a", d.forwarded.items[1]);
    try testing.expect(!d.router.pending());
    try d.press("ctrl+b");
    try testing.expect(d.router.pending());
    // The new delay too.
    try testing.expect(d.popup.visible());
    const rows = (try d.popupModel(a)).rows;
    try testing.expectEqualStrings("ctrl+b", rows[rows.len - 1].keys);
    try testing.expectEqualStrings("send-leader", rows[rows.len - 1].label);
    try d.press("ctrl+b");
    try testing.expectEqualStrings("ctrl+b", d.forwarded.items[2]);
}

test "a keys change during leader mode waits for it to end, so the next key is still the router's" {
    var l: Listed = undefined;
    try l.init(example_keys_list);
    defer l.deinit();
    const d = &l.d;
    try d.press("ctrl+a");
    const before = l.fake.count("keys.list");
    l.relist("{\"leader\":\"ctrl+b\",\"unlock\":\"ctrl+alt+b\",\"tables\":[]}");
    try d.handleLine("{\"type\":\"keys.changed\",\"data\":{\"layer\":\"product\",\"table\":\"venom\",\"revision\":2}}");
    try testing.expect(d.router.pending());
    try testing.expectEqual(before, l.fake.count("keys.list"));
    try d.press("v");
    try testing.expect(d.router.pending());
    try testing.expectEqual(@as(usize, 0), d.forwarded.items.len);
    // It ends, on a key or a timeout: the new tables and leader apply.
    try d.press("esc");
    try testing.expectEqual(before + 1, l.fake.count("keys.list"));
    try d.press("ctrl+b");
    try testing.expect(d.router.pending());
}

test "rail: the status segments as rows, the tray as a list, clicks run as this client" {
    var p: Pair = undefined;
    try pair(&p, 120, 60);
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    p.a.options.exec = Recorder.run;
    p.a.options.exec_ctx = &rec;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two tray members pushed by products, one with a verb click and one with
    // an exec click; a segment with a local click.
    try p.both("{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom-os.bat\",\"text\":\"81%\",\"icon\":\"B\",\"group\":\"tray\",\"priority\":50,\"click\":{\"verb\":\"pane.popup\",\"args\":\"{\\\"preset\\\":\\\"venom-os.power\\\",\\\"argv\\\":[\\\"power\\\"]}\"}}}}");
    try p.both("{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom-os.net\",\"text\":\"wifi\",\"icon\":\"N\",\"group\":\"tray\",\"priority\":40,\"click\":{\"exec\":[\"nm\",\"{pane}\"]}}}}");
    try p.both("{\"type\":\"status.changed\",\"data\":{\"segment\":{\"id\":\"venom.agents\",\"text\":\"2 running\",\"click\":{\"local\":\"inbox\"}}}}");
    try testing.expect(std.mem.indexOf(u8, try p.a.statusLine(a), "B N") != null);

    // Hidden by default; `leader b` shows it on the left, beside the panes.
    try testing.expect(p.a.railRect() == null);
    try p.a.local(.@"toggle-rail");
    const r = p.a.railRect().?;
    try testing.expectEqual(desk_mod.rail_width, r.width);
    try testing.expectEqual(@as(u16, desk_mod.rail_width), p.a.windowArea().x);
    try testing.expectEqual(@as(u16, 120 - desk_mod.rail_width), p.a.windowArea().width);
    const lines = try p.a.railLines(a);
    const has = struct {
        fn f(list: []const []const u8, want: []const u8) ?usize {
            for (list, 0..) |l, i| if (eq(u8, l, want)) return i;
            return null;
        }
    }.f;
    try testing.expectEqualStrings("status", lines[0]);
    for ([_][]const u8{ " s0", " ▸1 2", " tray", "  B 81%", "  N wifi", " 2 running", " ● build green" }) |want| {
        if (has(lines, want) == null) {
            std.debug.print("missing {s} in {any}\n", .{ want, lines });
            return error.TestUnexpectedResult;
        }
    }
    // The frame draws it, with a border column before the panes.
    const frame = try p.a.frame(a);
    try testing.expect(std.mem.startsWith(u8, frame[1], "status"));
    try testing.expect(std.mem.indexOf(u8, frame[1 + has(lines, "  B 81%").?], "  B 81%") != null);
    // B is narrow: no room for the rail, and the panes keep the width.
    try p.b.local(.@"toggle-rail");
    try testing.expect(p.b.railRect() == null);
    try testing.expectEqual(@as(u16, 0), p.b.windowArea().x);

    // A rail row's click runs the member's target as this client.
    const bat_row: u16 = @intCast(1 + has(lines, "  B 81%").?);
    try p.fake_a.reply("popup.ticket", "{\"ticket\":\"t1\",\"client\":\"c7\"}");
    try testing.expect(try p.a.click(3, bat_row));
    try testing.expectEqualStrings("{\"preset\":\"venom-os.power\",\"argv\":[\"power\"],\"ticket\":\"t1\"}", p.fake_a.last("pane.popup").?.params);
    const net_row: u16 = @intCast(1 + has(lines, "  N wifi").?);
    try testing.expect(try p.a.click(3, net_row));
    try testing.expectEqualStrings("nm", rec.argv.items[0]);
    try testing.expectEqualStrings("p0", rec.argv.items[1]);
    try testing.expect(try p.a.click(3, @intCast(1 + has(lines, " 2 running").?)));
    try testing.expectEqual(desk_mod.Overlay.inbox, p.a.view.overlay);
    p.a.view.overlay = .none;
    // The heading, a group's name and a segment without a target do
    // nothing, and the click is still the rail's, not a pane's.
    const calls = p.fake_a.calls.items.len;
    try testing.expect(try p.a.click(3, 1 + 0));
    try testing.expect(try p.a.click(3, @intCast(1 + has(lines, " tray").?)));
    try testing.expect(try p.a.click(3, @intCast(1 + has(lines, " s0").?)));
    try testing.expectEqual(calls, p.fake_a.calls.items.len);
    try testing.expectEqual(desk_mod.Overlay.none, p.a.view.overlay);
    // Below the rail and the status line, the cell is a pane's.
    try testing.expect(!try p.a.click(desk_mod.rail_width + 5, 5));

    // The status line: a click on a tray member runs it, as in venomx attach.
    var tray_x: ?u16 = null;
    for (try p.a.statusPlaced(a)) |pl| if (eq(u8, pl.id, "venomx.tray")) {
        tray_x = pl.x;
    };
    try testing.expect(try p.a.click(tray_x.? + 2, 0));
    try testing.expectEqual(@as(usize, 4), rec.argv.items.len);
    try testing.expectEqualStrings("nm", rec.argv.items[2]);

    // A config override's click wins over the product's.
    p.a.status_config.segments = &.{.{ .id = "venom.agents", .click = .{ .local = "palette" } }};
    try testing.expect(try p.a.click(3, @intCast(1 + has(lines, " 2 running").?)));
    try testing.expectEqual(desk_mod.Overlay.palette, p.a.view.overlay);

    // `toggle-segment` hides one on this client only, line and rail alike.
    try p.a.toggleSegment("venom.agents");
    try testing.expect(has(try p.a.railLines(a), " 2 running") == null);
    var on_b = false;
    for (try p.b.statusItems(a)) |it| on_b = on_b or eq(u8, it.id, "venom.agents");
    try testing.expect(on_b);
    try p.a.toggleSegment("venom.agents");
    try testing.expect(has(try p.a.railLines(a), " 2 running") != null);
}
