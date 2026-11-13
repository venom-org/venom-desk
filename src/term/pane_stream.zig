//! Emulating client for one pane stream, as venom-desk shows
//! a pane: S→C frames go to `handle`, C→S frames queue in `outbox`. Each
//! instance owns one venom-term Vt that never answers queries and keeps
//! this client's own viewport. The same protocol `venomx attach` speaks,
//! without its raw passthrough mode (venom-desk always emulates).
const std = @import("std");
const Vt = @import("vt").Vt;
const Value = std.json.Value;

/// Pane stream frame kinds.
pub const Kind = struct {
    pub const attach = 0x100;
    pub const attached = 0x101;
    pub const snapshot = 0x102;
    pub const ready = 0x103;
    pub const pty = 0x104;
    pub const scrollback = 0x105;
    pub const input = 0x106;
    pub const resize = 0x107;
    pub const resync = 0x108;
    pub const exit = 0x109;
    pub const err = 3;
    pub const close = 6;
};
/// The hello capability that offers pane streams.
pub const capability = "venomx.pane_stream";

pub const Size = Vt.Size;
pub const Out = struct {
    kind: u16,
    payload: []u8,
    pub fn deinit(self: Out, a: std.mem.Allocator) void {
        a.free(self.payload);
    }
};
pub const Exit = union(enum) { code: u8, signal: []u8 };
pub const Format = enum {
    ghostty,
    vt,
    fn name(self: Format) []const u8 {
        return if (self == .ghostty) Vt.ghostty_format else Vt.vt_format;
    }
};
pub const Phase = enum { attaching, snapshot, live, closed };

pub const PaneStream = struct {
    a: std.mem.Allocator,
    pane: []u8,
    id: u32,
    size: Size,
    reported: Size = .{ .cols = 0, .rows = 0 },
    history: u64,
    formats: []const Format = &.{ .ghostty, .vt },
    phase: Phase = .attaching,
    format: Format = .ghostty,
    source: ?[]u8 = null,
    writer: bool = false,
    pane_size: Size = .{ .cols = 1, .rows = 1 },
    snap: u32 = 0,
    decoder: ?Vt.Decoder = null,
    prefix: std.ArrayList(u8) = .empty,
    vt: ?Vt = null,
    offset: u64 = 0,
    discarding: bool = false,
    backfill_pending: bool = false,
    exit: ?Exit = null,
    closed: ?[]u8 = null,
    outbox: std.ArrayList(Out) = .empty,
    resyncs: u32 = 0,
    /// Bumped on every visible change; the renderer redraws on it.
    generation: u64 = 1,

    pub fn init(a: std.mem.Allocator, pane: []const u8, id: u32, size: Size, history: u64) !PaneStream {
        if (id % 2 == 0 or size.cols == 0 or size.rows == 0) return error.InvalidParams;
        return .{ .a = a, .pane = try a.dupe(u8, pane), .id = id, .size = size, .history = history };
    }
    pub fn deinit(self: *PaneStream) void {
        if (self.decoder) |*d| d.deinit();
        if (self.vt) |*v| v.deinit();
        self.prefix.deinit(self.a);
        if (self.source) |src| self.a.free(src);
        if (self.exit) |e| if (e == .signal) self.a.free(e.signal);
        if (self.closed) |c| self.a.free(c);
        for (self.outbox.items) |o| o.deinit(self.a);
        self.outbox.deinit(self.a);
        self.a.free(self.pane);
    }
    fn queue(self: *PaneStream, kind: u16, value: anytype) !void {
        const payload = try std.json.Stringify.valueAlloc(self.a, value, .{ .emit_null_optional_fields = false });
        errdefer self.a.free(payload);
        try self.outbox.append(self.a, .{ .kind = kind, .payload = payload });
    }
    fn formatNames(self: *const PaneStream, buf: *[2][]const u8) []const []const u8 {
        for (self.formats, 0..) |f, i| buf[i] = f.name();
        return buf[0..self.formats.len];
    }
    pub const Resume = struct { source: []const u8, offset: u64 };
    /// Queue ATTACH. venom-desk claims input like `venomx attach`.
    pub fn attach(self: *PaneStream, @"resume": ?Resume) !void {
        var names: [2][]const u8 = undefined;
        try self.queue(Kind.attach, .{ .pane = self.pane, .mode = "emulate", .formats = self.formatNames(&names), .size = self.size, .history = self.history, .claim = true, .@"resume" = @"resume" });
        self.phase = .attaching;
        self.reported = self.size;
    }
    /// After a reconnect: reuse the emulator and ask to resume on `id`.
    pub fn reattach(self: *PaneStream, id: u32) !void {
        for (self.outbox.items) |o| o.deinit(self.a);
        self.outbox.clearRetainingCapacity();
        self.id = id;
        self.discarding = false;
        if (self.decoder) |*d| d.deinit();
        self.decoder = null;
        const resumable = self.vt != null and self.source != null and self.phase == .live;
        try self.attach(if (resumable) .{ .source = self.source.?, .offset = self.offset } else null);
    }
    /// Hand the queued C→S frames to `send`, oldest first. A frame leaves the
    /// outbox before it is freed, so when `send` fails part-way the stream
    /// still owns exactly the frames not yet sent (freeing in a
    /// `defer` and clearing afterwards would free them twice on an error).
    pub fn flush(self: *PaneStream, ctx: anytype, comptime send: fn (@TypeOf(ctx), u32, Out) anyerror!void) !void {
        var sent: usize = 0;
        defer {
            for (self.outbox.items[0..sent]) |o| o.deinit(self.a);
            const left = self.outbox.items.len - sent;
            std.mem.copyForwards(Out, self.outbox.items[0..left], self.outbox.items[sent..]);
            self.outbox.items.len = left;
        }
        for (self.outbox.items) |o| {
            try send(ctx, self.id, o);
            sent += 1;
        }
    }
    /// Bytes for the pane's PTY; dropped unless this client is a writer.
    pub fn input(self: *PaneStream, bytes: []const u8) !void {
        if (!self.writer or self.phase == .attaching or self.phase == .closed or bytes.len == 0) return;
        try self.outbox.append(self.a, .{ .kind = Kind.input, .payload = try self.a.dupe(u8, bytes) });
    }
    /// This client's viewport for the pane.
    pub fn viewport(self: *PaneStream, size: Size) !void {
        if (size.cols == 0 or size.rows == 0) return;
        self.size = size;
        try self.report();
    }
    fn report(self: *PaneStream) !void {
        if (!self.writer or self.phase == .attaching or self.phase == .closed or std.meta.eql(self.size, self.reported)) return;
        try self.queue(Kind.resize, self.size);
        self.reported = self.size;
    }
    pub fn requestResync(self: *PaneStream) !void {
        if (self.phase != .live or self.discarding) return;
        var names: [2][]const u8 = undefined;
        try self.queue(Kind.resync, .{ .mode = "emulate", .formats = self.formatNames(&names), .history = self.history });
        self.discarding = true;
        self.resyncs += 1;
    }
    pub fn detach(self: *PaneStream) !void {
        if (self.phase == .closed) return;
        try self.outbox.append(self.a, .{ .kind = Kind.close, .payload = try self.a.dupe(u8, "{}") });
        try self.close("detached");
    }
    fn close(self: *PaneStream, reason: []const u8) !void {
        if (self.closed == null) self.closed = try self.a.dupe(u8, reason);
        self.phase = .closed;
        self.changed();
    }
    fn changed(self: *PaneStream) void {
        self.generation +%= 1;
    }

    pub fn handle(self: *PaneStream, kind: u16, payload: []const u8) !void {
        if (self.phase == .closed) return;
        switch (kind) {
            Kind.attached => try self.onAttached(payload),
            Kind.snapshot => try self.onSnapshot(payload),
            Kind.ready => try self.onReady(payload),
            Kind.pty => try self.onPty(payload),
            Kind.scrollback => try self.onScrollback(payload),
            Kind.resize => try self.onResize(payload),
            Kind.resync => try self.onResync(payload),
            Kind.exit => try self.onExit(payload),
            Kind.close, Kind.err => {
                const parsed = std.json.parseFromSlice(Value, self.a, payload, .{}) catch null;
                defer if (parsed) |p| p.deinit();
                const key = if (kind == Kind.close) "reason" else "code";
                try self.close(if (parsed) |p| string(p.value, key) orelse "closed" else "closed");
            },
            else => return error.BadFrame,
        }
    }
    fn onAttached(self: *PaneStream, payload: []const u8) !void {
        if (self.phase != .attaching) return error.BadFrame;
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const source = string(v, "source") orelse return error.BadFrame;
        const format_name = string(v, "format") orelse return error.BadFrame;
        self.format = if (std.mem.eql(u8, format_name, Vt.ghostty_format)) .ghostty else if (std.mem.eql(u8, format_name, Vt.vt_format)) .vt else return error.BadFrame;
        const owned = try self.a.dupe(u8, source);
        if (self.source) |old| self.a.free(old);
        self.source = owned;
        self.writer = boolean(v, "input") orelse false;
        if (field(v, "size")) |sz| self.pane_size = try parseSize(sz);
        if (boolean(v, "resumed") orelse false) {
            const at = try uint(field(v, "offset") orelse return error.BadFrame);
            if (self.vt == null or at != self.offset) return error.BadFrame;
            self.phase = .live;
        } else {
            self.phase = .snapshot;
            self.snap = 0;
            self.prefix.clearRetainingCapacity();
        }
        try self.report();
        self.changed();
    }
    fn onSnapshot(self: *PaneStream, payload: []const u8) !void {
        if (self.discarding) return;
        if (self.phase != .snapshot or payload.len < 12) return error.BadFrame;
        const snap = std.mem.readInt(u32, payload[0..4], .big);
        if (snap != self.snap) {
            if (snap <= self.snap) return error.BadFrame;
            self.snap = snap;
            if (self.decoder) |*d| d.deinit();
            self.decoder = null;
            self.prefix.clearRetainingCapacity();
            if (self.format == .ghostty) self.decoder = try Vt.Decoder.init(self.a, .{});
        }
        const bytes = payload[12..];
        if (self.decoder) |d| try d.feedPrefix(bytes) else try self.prefix.appendSlice(self.a, bytes);
    }
    fn onReady(self: *PaneStream, payload: []const u8) !void {
        if (self.discarding) return;
        if (self.phase != .snapshot) return error.BadFrame;
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const snap = try uint(field(v, "snap") orelse return error.BadFrame);
        if (snap != self.snap) {
            if (snap < self.snap or self.decoder != null or self.prefix.items.len != 0) return error.BadFrame;
            self.snap = @intCast(snap);
            if (self.format == .ghostty) self.decoder = try Vt.Decoder.init(self.a, .{});
        }
        const meta: Vt.Ready = .{
            .epoch = try uint(field(v, "epoch") orelse return error.BadFrame),
            .oldest = try uint(field(v, "oldest") orelse return error.BadFrame),
            .top = try uint(field(v, "top") orelse return error.BadFrame),
            .active = try uint(field(v, "active") orelse return error.BadFrame),
            .cols = std.math.cast(u16, try uint(field(v, "cols") orelse return error.BadFrame)) orelse return error.BadFrame,
            .rows = std.math.cast(u16, try uint(field(v, "rows") orelse return error.BadFrame)) orelse return error.BadFrame,
        };
        const offset = try uint(field(v, "offset") orelse return error.BadFrame);
        var fresh = self.build(meta) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Undecodable snapshot: keep the old screen and ask again.
            self.phase = .live;
            self.discarding = false;
            return self.requestResync();
        };
        errdefer fresh.deinit();
        if (self.vt) |*old| old.deinit();
        self.vt = fresh;
        self.offset = offset;
        self.pane_size = .{ .cols = meta.cols, .rows = meta.rows };
        self.discarding = false;
        self.phase = .live;
        self.backfill_pending = self.format == .ghostty;
        self.changed();
    }
    fn build(self: *PaneStream, meta: Vt.Ready) !Vt {
        switch (self.format) {
            .ghostty => {
                if (self.decoder == null) return error.InvalidSnapshot;
                defer self.decoder = null;
                return self.decoder.?.ready(meta) catch |err| {
                    self.decoder.?.deinit();
                    return err;
                };
            },
            .vt => {
                defer self.prefix.clearRetainingCapacity();
                var live = try Vt.init(self.a, .{ .cols = meta.cols, .rows = meta.rows });
                errdefer live.deinit();
                try live.feed(self.prefix.items);
                return live;
            },
        }
    }
    fn onPty(self: *PaneStream, payload: []const u8) !void {
        if (payload.len < 8) return error.BadFrame;
        if (self.phase != .live or self.discarding) return;
        const at = std.mem.readInt(u64, payload[0..8], .big);
        if (at != self.offset) return self.requestResync();
        try self.vt.?.feed(payload[8..]);
        self.offset += payload.len - 8;
        self.changed();
    }
    fn onScrollback(self: *PaneStream, payload: []const u8) !void {
        if (payload.len < 21) return error.BadFrame;
        const snap = std.mem.readInt(u32, payload[0..4], .big);
        if (snap != self.snap or !self.backfill_pending) return;
        const vt = self.vt orelse return;
        const flags = payload[20];
        const bytes = payload[21..];
        if (bytes.len != 0 and !self.discarding) {
            _ = vt.feedHistory(bytes) catch |err| switch (err) {
                error.StaleRows => {
                    vt.abandonHistory();
                    self.backfill_pending = false;
                    self.changed();
                    return;
                },
                else => return err,
            };
            self.changed();
        }
        if (flags & 1 != 0) {
            if (flags & 2 != 0 or vt.historyPending()) vt.abandonHistory();
            self.backfill_pending = false;
            self.changed();
        }
    }
    fn onResize(self: *PaneStream, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const size = try parseSize(v);
        if (self.phase != .live or self.discarding) {
            self.pane_size = size;
            return;
        }
        const at = try uint(field(v, "offset") orelse return error.BadFrame);
        if (at != self.offset) return self.requestResync();
        try self.vt.?.resize(size.cols, size.rows);
        self.pane_size = size;
        self.changed();
    }
    fn onResync(self: *PaneStream, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        if (self.phase == .attaching) return error.BadFrame;
        self.writer = boolean(parsed.value, "input") orelse self.writer;
        self.phase = .snapshot;
        self.discarding = false;
        if (self.vt) |vt| if (vt.historyPending()) vt.abandonHistory();
        self.backfill_pending = false;
        self.changed();
    }
    fn onExit(self: *PaneStream, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const st: Exit = if (field(v, "exit_code")) |code|
            .{ .code = std.math.cast(u8, try uint(code)) orelse return error.BadFrame }
        else
            .{ .signal = try self.a.dupe(u8, string(v, "signal") orelse "unknown") };
        if (self.exit) |e| if (e == .signal) self.a.free(e.signal);
        self.exit = st;
        self.changed();
    }
};

fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn boolean(v: Value, key: []const u8) ?bool {
    const f = field(v, key) orelse return null;
    return if (f == .bool) f.bool else null;
}
fn uint(v: Value) !u64 {
    if (v != .integer or v.integer < 0) return error.BadFrame;
    return @intCast(v.integer);
}
fn parseSize(v: Value) !Size {
    const cols = std.math.cast(u16, try uint(field(v, "cols") orelse return error.BadFrame)) orelse return error.BadFrame;
    const rows = std.math.cast(u16, try uint(field(v, "rows") orelse return error.BadFrame)) orelse return error.BadFrame;
    if (cols == 0 or rows == 0) return error.BadFrame;
    return .{ .cols = cols, .rows = rows };
}

const t = std.testing;

test "attach, vt snapshot, live pty and input as a writer" {
    var s = try PaneStream.init(t.allocator, "p1", 1, .{ .cols = 10, .rows = 3 }, 0);
    defer s.deinit();
    try s.attach(null);
    try t.expectEqual(@as(usize, 1), s.outbox.items.len);
    try t.expectEqual(@as(u16, Kind.attach), s.outbox.items[0].kind);
    try s.handle(Kind.attached, "{\"source\":\"x/1\",\"format\":\"vt\",\"input\":true,\"size\":{\"cols\":10,\"rows\":3}}");
    var snap: [12 + 5]u8 = undefined;
    std.mem.writeInt(u32, snap[0..4], 1, .big);
    @memset(snap[4..12], 0);
    @memcpy(snap[12..], "hello");
    try s.handle(Kind.snapshot, &snap);
    try s.handle(Kind.ready, "{\"snap\":1,\"epoch\":0,\"oldest\":0,\"top\":0,\"active\":0,\"cols\":10,\"rows\":3,\"offset\":7}");
    try t.expectEqual(Phase.live, s.phase);
    var pty: [8 + 3]u8 = undefined;
    std.mem.writeInt(u64, pty[0..8], 7, .big);
    @memcpy(pty[8..], " yo");
    try s.handle(Kind.pty, &pty);
    try t.expectEqual(@as(u64, 10), s.offset);
    // A gap asks for a fresh snapshot instead of drawing a wrong screen.
    std.mem.writeInt(u64, pty[0..8], 99, .big);
    try s.handle(Kind.pty, &pty);
    try t.expect(s.discarding);
    try s.input("a");
    try s.detach();
    try t.expectEqual(Phase.closed, s.phase);
}

test "flush: a failing send leaves the unsent frames owned once" {
    var s = try PaneStream.init(t.allocator, "p1", 3, .{ .cols = 10, .rows = 3 }, 0);
    defer s.deinit();
    try s.attach(null);
    try s.detach();
    try t.expectEqual(@as(usize, 2), s.outbox.items.len);
    const Sink = struct {
        sent: usize = 0,
        fail_at: usize,
        fn send(self: *@This(), id: u32, o: Out) anyerror!void {
            try t.expectEqual(@as(u32, 3), id);
            if (self.sent == self.fail_at) return error.SlowReader;
            _ = o;
            self.sent += 1;
        }
    };
    // The first frame goes out, the second fails: only the second stays.
    var sink: Sink = .{ .fail_at = 1 };
    try t.expectError(error.SlowReader, s.flush(&sink, Sink.send));
    try t.expectEqual(@as(usize, 1), s.outbox.items.len);
    try t.expectEqual(@as(u16, Kind.close), s.outbox.items[0].kind);
    // A retry sends the rest; nothing is freed twice or leaked (deinit).
    var ok: Sink = .{ .fail_at = 99 };
    try s.flush(&ok, Sink.send);
    try t.expectEqual(@as(usize, 1), ok.sent);
    try t.expectEqual(@as(usize, 0), s.outbox.items.len);
}
