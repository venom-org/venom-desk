//! The command palette: the verbs of every product schema
//! venom-desk can reach (venomx, venom and any configured product), so a product gets
//! palette entries for free. Schemas are read through each binary's
//! generated MCP adapter (`<tool> mcp`, `tools/list`): it is
//! part of every agent-contract binary, needs no daemon, and lists exactly
//! the remote verbs (local commands such as `attach` are not tools).
const std = @import("std");
const json = @import("json.zig");
const keys = @import("keys.zig");
const Value = std.json.Value;

/// The products the palette reaches by default, in palette order.
pub const default_products = [_][]const u8{ "venomx", "venom" };

/// MCP tool names encode verb names: `_d` → `.`, `__` → `_`. Allocated in `a`.
pub fn decodeToolName(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '_') {
            if (i + 1 >= name.len) return error.InvalidToolName;
            switch (name[i + 1]) {
                'd' => try out.append(a, '.'),
                '_' => try out.append(a, '_'),
                else => return error.InvalidToolName,
            }
            i += 1;
        } else try out.append(a, name[i]);
    }
    return out.toOwnedSlice(a);
}

pub const Param = struct { name: []const u8, required: bool };

pub const Entry = struct {
    /// `venomx`, `venom`, … or `venom-desk` for this client's own actions.
    tool: []const u8,
    /// Wire verb (`pane.split`) or local action name.
    verb: []const u8,
    summary: []const u8,
    params: []const Param = &.{},
    local: ?keys.Local = null,
    /// "tool verb summary", lower case, for matching.
    haystack: []const u8,

    /// The CLI spelling: `venomx pane split`.
    pub fn command(self: Entry, a: std.mem.Allocator) ![]u8 {
        const verb = try a.dupe(u8, self.verb);
        std.mem.replaceScalar(u8, verb, '.', ' ');
        return std.fmt.allocPrint(a, "{s} {s}", .{ self.tool, verb });
    }
};

pub const Palette = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Products whose schema was read.
    reachable: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Palette {
        return .{ .arena = .init(gpa) };
    }
    pub fn deinit(self: *Palette) void {
        self.arena.deinit();
    }
    fn haystack(a: std.mem.Allocator, tool: []const u8, verb: []const u8, summary: []const u8) ![]u8 {
        const h = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ tool, verb, summary });
        for (h) |*c| c.* = std.ascii.toLower(c.*);
        return h;
    }
    /// This client's own actions, so the palette also covers the UI.
    pub fn addLocals(self: *Palette) !void {
        const a = self.arena.allocator();
        for (std.enums.values(keys.Local)) |l| {
            const name = @tagName(l);
            try self.entries.append(a, .{ .tool = "venom-desk", .verb = name, .summary = "local action", .local = l, .haystack = try haystack(a, "venom-desk", name, "local action") });
        }
    }
    /// Add one product's `tools/list` result (`{tools:[{name, description,
    /// inputSchema}]}`).
    pub fn addTools(self: *Palette, tool: []const u8, result: Value) !void {
        const a = self.arena.allocator();
        const tools = json.array(result, "tools") orelse return error.BadSchema;
        const owned_tool = try a.dupe(u8, tool);
        try self.reachable.append(a, owned_tool);
        for (tools) |t| {
            const verb = try decodeToolName(a, json.str(t, "name") orelse return error.BadSchema);
            const summary = try a.dupe(u8, json.str(t, "description") orelse "");
            var params: std.ArrayList(Param) = .empty;
            const input = json.get(t, "inputSchema") orelse Value.null;
            const required = json.array(input, "required") orelse &.{};
            if (json.get(input, "properties")) |props| if (props == .object) {
                var it = props.object.iterator();
                while (it.next()) |e| {
                    var req = false;
                    for (required) |r| req = req or (r == .string and std.mem.eql(u8, r.string, e.key_ptr.*));
                    try params.append(a, .{ .name = try a.dupe(u8, e.key_ptr.*), .required = req });
                }
            };
            try self.entries.append(a, .{ .tool = owned_tool, .verb = verb, .summary = summary, .params = params.items, .haystack = try haystack(a, tool, verb, summary) });
        }
    }
    /// Parse the stdout of `<tool> mcp` (one JSON-RPC message per line) and
    /// add the `tools/list` reply with id 2.
    pub fn addMcpOutput(self: *Palette, tool: []const u8, stdout: []const u8) !void {
        var lines = std.mem.splitScalar(u8, stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(Value, self.arena.child_allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const id = json.int(parsed.value, "id") orelse continue;
            if (id != 2) continue;
            return self.addTools(tool, json.get(parsed.value, "result") orelse return error.BadSchema);
        }
        return error.BadSchema;
    }

    pub const Match = struct { entry: *const Entry, score: i32 };
    /// Entries matching every character of `query` in order (fuzzy
    /// subsequence), best first: word starts and runs score higher.
    pub fn filter(self: *const Palette, a: std.mem.Allocator, query: []const u8) ![]Match {
        var out: std.ArrayList(Match) = .empty;
        for (self.entries.items) |*e| if (score(e.haystack, query)) |s| try out.append(a, .{ .entry = e, .score = s });
        std.mem.sort(Match, out.items, {}, struct {
            fn f(_: void, x: Match, y: Match) bool {
                if (x.score != y.score) return x.score > y.score;
                const c = std.mem.order(u8, x.entry.tool, y.entry.tool);
                if (c != .eq) return c == .lt;
                return std.mem.lessThan(u8, x.entry.verb, y.entry.verb);
            }
        }.f);
        return out.toOwnedSlice(a);
    }
};

fn score(haystack: []const u8, query: []const u8) ?i32 {
    var s: i32 = 0;
    var hi: usize = 0;
    var prev: ?usize = null;
    for (query) |qc| {
        if (qc == ' ') continue;
        const q = std.ascii.toLower(qc);
        while (hi < haystack.len and haystack[hi] != q) hi += 1;
        if (hi >= haystack.len) return null;
        s += 1;
        if (hi == 0 or haystack[hi - 1] == ' ' or haystack[hi - 1] == '.' or haystack[hi - 1] == '-' or haystack[hi - 1] == '_') s += 4;
        if (prev != null and prev.? + 1 == hi) s += 3;
        prev = hi;
        hi += 1;
    }
    return s;
}

/// MCP requests sent to `<tool> mcp` on stdin.
pub const mcp_requests =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"venom-desk","version":"0.0.0"}}}
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    \\
;

/// Read one product's schema by running `<exe> mcp`. `exe` is a path or a
/// name on PATH. A missing binary is `error.FileNotFound` (unreachable).
pub fn readProduct(gpa: std.mem.Allocator, io: std.Io, exe: []const u8) ![]u8 {
    var child = try std.process.spawn(io, .{ .argv = &.{ exe, "mcp" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    defer child.kill(io);
    {
        var buf: [512]u8 = undefined;
        var w = child.stdin.?.writer(io, &buf);
        try w.interface.writeAll(mcp_requests);
        try w.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var rbuf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &rbuf);
    const out = try r.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024));
    errdefer gpa.free(out);
    _ = try child.wait(io);
    return out;
}

/// Read every reachable product; unreachable ones are skipped.
pub fn discover(self: *Palette, gpa: std.mem.Allocator, io: std.Io, products: []const []const u8) !void {
    for (products) |p| {
        const out = readProduct(gpa, io, p) catch continue;
        defer gpa.free(out);
        const tool = std.fs.path.basename(p);
        self.addMcpOutput(tool, out) catch continue;
    }
}

test "tool names decode reversibly" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{ .{ "pane_dsplit", "pane.split" }, .{ "pane_dcapture__rows", "pane.capture_rows" }, .{ "doctor", "doctor" }, .{ "pane__split", "pane_split" } };
    for (cases) |c| {
        const got = try decodeToolName(a, c[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
    try std.testing.expectError(error.InvalidToolName, decodeToolName(a, "bad_x"));
}

/// A `venom` tools/list fixture: venom has no binary yet, so the palette
/// test stands in for it with the example verbs.
pub const venom_fixture =
    \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"venom","version":"0.0.0"}}}
    \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"approve","description":"Approve the pending request of an agent pane","inputSchema":{"type":"object","properties":{"pane":{"type":"string"}},"required":["pane"]}},{"name":"thread_dpick","description":"Pick a thread in a popup","inputSchema":{"type":"object","properties":{"ticket":{"type":"string"}},"required":["ticket"]}},{"name":"settings","description":"Open venom settings","inputSchema":{"type":"object","properties":{},"required":[]}}]}}
;
pub const venomx_fixture =
    \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"pane_dsplit","description":"Split a pane","inputSchema":{"type":"object","properties":{"pane":{"type":"string"},"axis":{"type":"string"}},"required":["pane","axis"]}},{"name":"status_dset","description":"Set a status segment","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"}},"required":["id","text"]}},{"name":"pane_dattention","description":"Set or clear pane attention","inputSchema":{"type":"object","properties":{"pane":{"type":"string"}},"required":["pane"]}}]}}
;

test "palette lists venomx and venom verbs and filters them" {
    const a = std.testing.allocator;
    var p = Palette.init(a);
    defer p.deinit();
    try p.addMcpOutput("venomx", venomx_fixture);
    try p.addMcpOutput("venom", venom_fixture);
    try p.addLocals();
    try std.testing.expectEqual(@as(usize, 2), p.reachable.items.len);
    var saw = [2]bool{ false, false };
    for (p.entries.items) |e| {
        if (std.mem.eql(u8, e.tool, "venomx") and std.mem.eql(u8, e.verb, "pane.split")) saw[0] = true;
        if (std.mem.eql(u8, e.tool, "venom") and std.mem.eql(u8, e.verb, "thread.pick")) saw[1] = true;
    }
    try std.testing.expect(saw[0] and saw[1]);
    const m = try p.filter(a, "split");
    defer a.free(m);
    try std.testing.expectEqualStrings("pane.split", m[0].entry.verb);
    const approve = try p.filter(a, "venom appr");
    defer a.free(approve);
    try std.testing.expectEqualStrings("approve", approve[0].entry.verb);
    try std.testing.expectEqual(@as(usize, 1), approve[0].entry.params.len);
    try std.testing.expect(approve[0].entry.params[0].required);
    const none = try p.filter(a, "zzzz");
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try std.testing.expectEqualStrings("venomx pane split", try m[0].entry.command(fba.allocator()));
    try std.testing.expectError(error.BadSchema, p.addMcpOutput("broken", "not json\n"));
}
