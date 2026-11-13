//! venom-desk's link to the venomx daemon. Every mutation is an ordinary
//! schema verb sent with this client's own identity, so the
//! UI can do nothing an agent could not do through the CLI or MCP. `Client`
//! is an interface: `Wire` speaks NDJSON over the daemon socket,
//! and `Fake` records calls for tests (test/live.py runs the same paths
//! against a real venomx).
const std = @import("std");
const proto = @import("proto");
const Value = std.json.Value;

pub const Reply = union(enum) {
    ok: Value,
    /// The error code, e.g. `unsupported.verb`.
    err: []const u8,
};

pub const Client = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// `params` is a JSON object; the reply is allocated in `arena`.
        call: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, verb: []const u8, params: []const u8) anyerror!Reply,
    };
    pub fn callJson(self: Client, arena: std.mem.Allocator, verb: []const u8, params: []const u8) !Reply {
        return self.vtable.call(self.ptr, arena, verb, params);
    }
    pub fn call(self: Client, arena: std.mem.Allocator, verb: []const u8, params: anytype) !Reply {
        // `.{}` is an empty tuple, which JSON-encodes as `[]`; params must be
        // an object, so it is sent as `{}`.
        if (@TypeOf(params) == @TypeOf(.{})) return self.callJson(arena, verb, "{}");
        const text = try std.json.Stringify.valueAlloc(arena, params, .{ .emit_null_optional_fields = false });
        return self.callJson(arena, verb, text);
    }
};

/// Records every call; answers from a table of canned replies, or `{}`.
/// Verbs listed in `missing` answer `unsupported.verb`, as a venomx without
/// without `keys.list` or floats and popups would.
pub const Fake = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,
    replies: std.ArrayList(Canned) = .empty,
    missing: []const []const u8 = &.{},
    /// Verbs that fail with an error code: `.{ verb, code }`.
    failing: []const [2][]const u8 = &.{},

    pub const Call = struct { verb: []u8, params: []u8 };
    const Canned = struct { verb: []const u8, json: []const u8 };

    pub fn init(gpa: std.mem.Allocator) Fake {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Fake) void {
        for (self.calls.items) |c| {
            self.gpa.free(c.verb);
            self.gpa.free(c.params);
        }
        self.calls.deinit(self.gpa);
        self.replies.deinit(self.gpa);
    }
    pub fn reply(self: *Fake, verb: []const u8, json: []const u8) !void {
        try self.replies.append(self.gpa, .{ .verb = verb, .json = json });
    }
    pub fn client(self: *Fake) Client {
        return .{ .ptr = self, .vtable = &.{ .call = callFn } };
    }
    fn callFn(ptr: *anyopaque, arena: std.mem.Allocator, verb: []const u8, params: []const u8) anyerror!Reply {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        const v = try self.gpa.dupe(u8, verb);
        errdefer self.gpa.free(v);
        const p = try self.gpa.dupe(u8, params);
        errdefer self.gpa.free(p);
        try self.calls.append(self.gpa, .{ .verb = v, .params = p });
        for (self.missing) |m| if (std.mem.eql(u8, m, verb)) return .{ .err = "unsupported.verb" };
        for (self.failing) |f| if (std.mem.eql(u8, f[0], verb)) return .{ .err = f[1] };
        for (self.replies.items) |r| if (std.mem.eql(u8, r.verb, verb)) return .{ .ok = try std.json.parseFromSliceLeaky(Value, arena, r.json, .{ .allocate = .alloc_always }) };
        return .{ .ok = .{ .object = .empty } };
    }
    /// Calls of one verb, in order.
    pub fn count(self: *const Fake, verb: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| if (std.mem.eql(u8, c.verb, verb)) {
            n += 1;
        };
        return n;
    }
    pub fn last(self: *const Fake, verb: []const u8) ?Call {
        var i = self.calls.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.calls.items[i].verb, verb)) return self.calls.items[i];
        }
        return null;
    }
};

/// NDJSON connection to `venomx serve`. One connection carries
/// both blocking verb calls and the `events` subscription; event items that
/// arrive while a call waits are queued for `nextEvent`.
pub const Wire = struct {
    gpa: std.mem.Allocator,
    client: proto.Client,
    next_id: i64 = 10,
    events_id: ?i64 = null,
    queued: std.ArrayList([]u8) = .empty,
    timeout_ms: i64 = 10_000,

    pub const Options = struct {
        socket: ?[]const u8 = null,
        environ: ?std.process.Environ = null,
        token: ?[]const u8 = null,
        /// Daemon to talk to (`venomx`, or `venom-desk` for its own daemon).
        tool: []const u8 = "venomx",
        /// Budget for the hello handshake.
        connect_ms: i64 = 10_000,
    };
    pub fn connect(gpa: std.mem.Allocator, options: Options) !Wire {
        var c = try proto.Client.init(gpa, .{
            .tool = options.tool,
            .path = .{ .socket = options.socket, .environ = options.environ },
            .protocol = .ndjson,
            .token = options.token,
            .hello = .{ .identity = .{ .name = "venom-desk", .version = "0.0.0" }, .caps = &.{"cancel"} },
        });
        errdefer c.deinit();
        const deadline = proto.os.nowMs() + options.connect_ms;
        while (!try c.pollHello(100)) {
            if (proto.os.nowMs() > deadline) return error.Timeout;
        }
        return .{ .gpa = gpa, .client = c };
    }
    pub fn deinit(self: *Wire) void {
        for (self.queued.items) |q| self.gpa.free(q);
        self.queued.deinit(self.gpa);
        self.client.deinit();
    }
    pub fn asClient(self: *Wire) Client {
        return .{ .ptr = self, .vtable = &.{ .call = callFn } };
    }
    fn line(msg: proto.Message) ?[]const u8 {
        return switch (msg) {
            .ndjson => |l| l,
            .frame => null,
        };
    }
    fn callFn(ptr: *anyopaque, arena: std.mem.Allocator, verb: []const u8, params: []const u8) anyerror!Reply {
        const self: *Wire = @ptrCast(@alignCast(ptr));
        const id = self.next_id;
        self.next_id += 1;
        const verb_json = try std.json.Stringify.valueAlloc(self.gpa, verb, .{});
        defer self.gpa.free(verb_json);
        const body = try std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"verb\":{s},\"params\":{s}}}", .{ id, verb_json, params });
        defer self.gpa.free(body);
        try self.client.connection.sendMessage(.{ .ndjson = body });
        const start = proto.os.nowMs();
        while (proto.os.nowMs() - start < self.timeout_ms) {
            const msg = try self.client.receive(100) orelse continue;
            const text = line(msg) orelse continue;
            var r = proto.Response.parse(self.gpa, text) catch continue;
            defer r.deinit();
            const rid = if (r.id) |x| switch (x) {
                .integer => |i| i,
                else => continue,
            } else continue;
            if (rid == id) return switch (r.body) {
                .ok => |v| .{ .ok = try clone(arena, v) },
                .@"error" => |e| .{ .err = try arena.dupe(u8, e.code) },
                .item => continue,
            };
            if (self.events_id != null and rid == self.events_id.? and r.body == .item) try self.queued.append(self.gpa, try std.json.Stringify.valueAlloc(self.gpa, r.body.item, .{}));
        }
        return error.Timeout;
    }
    /// Start the `events` stream with these type filters.
    pub fn subscribe(self: *Wire, types: []const []const u8) !void {
        self.events_id = 1;
        try self.client.request(@as(i64, 1), "events", .{ .types = types });
    }
    /// The next event item as JSON text (caller frees), waiting at most
    /// `timeout_ms`.
    pub fn nextEvent(self: *Wire, timeout_ms: i32) !?[]u8 {
        if (self.queued.items.len > 0) return self.queued.orderedRemove(0);
        const msg = try self.client.receive(timeout_ms) orelse return null;
        const text = line(msg) orelse return null;
        var r = proto.Response.parse(self.gpa, text) catch return null;
        defer r.deinit();
        const rid = if (r.id) |x| switch (x) {
            .integer => |i| i,
            else => return null,
        } else return null;
        if (rid != self.events_id orelse return null) return null;
        return switch (r.body) {
            .item => |v| try std.json.Stringify.valueAlloc(self.gpa, v, .{}),
            .@"error" => error.EventsFailed,
            .ok => error.EventsEnded,
        };
    }
};

fn clone(a: std.mem.Allocator, v: Value) !Value {
    const text = try std.json.Stringify.valueAlloc(a, v, .{});
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
}

test "fake records calls and answers missing verbs as unsupported" {
    const a = std.testing.allocator;
    var fake = Fake.init(a);
    defer fake.deinit();
    fake.missing = &.{"keys.list"};
    try fake.reply("status.list", "{\"segments\":[]}");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const c = fake.client();
    try std.testing.expect((try c.call(arena.allocator(), "keys.list", .{})) == .err);
    const r = try c.call(arena.allocator(), "status.list", .{ .scope = "s0" });
    try std.testing.expect(r.ok.object.get("segments") != null);
    try std.testing.expectEqualStrings("{\"scope\":\"s0\"}", fake.last("status.list").?.params);
}
