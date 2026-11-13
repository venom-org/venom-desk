//! `venom-desk attach --session <s>`: the full-screen presentation client
//! in place of `venomx attach`. One binary connection to
//! venomx carries CONTROL (the client's own verbs and its `events`
//! subscription) and one odd-ID stream per shown pane. The headless
//! `Desk` decides what is shown and what keys do; this layer owns the host
//! terminal (raw mode, Kitty keyboard, mouse, bracketed paste), the pane
//! emulators and the `exec` children.
const std = @import("std");
const proto = @import("proto");
const cli = @import("cli");
const term = @import("venom-term");
const desk_mod = @import("venom-desk");
const PaneStream = @import("pane_stream.zig").PaneStream;
const pane_stream = @import("pane_stream.zig");
const render = @import("render.zig");
const exec = @import("exec.zig");
const Desk = desk_mod.Desk;
const keys = desk_mod.keys;
const Reply = desk_mod.client.Reply;
const posix = std.posix;
const Value = std.json.Value;
const eq = std.mem.eql;

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    stopped: *const std.atomic.Value(bool),
};

fn failure(code: []const u8, message: []const u8) cli.Local.Outcome {
    return .{ .failure = .{ .code = code, .message = message } };
}
fn nowMs() i64 {
    return proto.os.nowMs();
}

// ------------------------------------------------------------- the link

const events_id: i64 = 2;

/// The venomx connection as a `desk.client.Client`: blocking verb calls on
/// the same binary connection that carries the pane streams. Frames and
/// event items that arrive while a call waits are held for the loop.
pub const Link = struct {
    gpa: std.mem.Allocator,
    client: proto.Client,
    next_id: i64 = 10,
    held: std.ArrayList(Held) = .empty,
    timeout_ms: i64 = 10_000,
    /// The CONTROL stream closed or failed.
    lost: bool = false,
    /// A waiting call gives up with error.Interrupted once this is set (or
    /// the host terminal hung up), so a stop never waits out `timeout_ms`.
    stopped: ?*const std.atomic.Value(bool) = null,

    pub const Held = struct { kind: u16, stream: u32, payload: []u8 };

    pub fn deinit(self: *Link) void {
        for (self.held.items) |h| self.gpa.free(h.payload);
        self.held.deinit(self.gpa);
        self.client.deinit();
    }
    pub fn conn(self: *Link) *proto.Connection {
        return &self.client.connection;
    }
    pub fn asClient(self: *Link) desk_mod.client.Client {
        return .{ .ptr = self, .vtable = &.{ .call = callFn } };
    }
    fn interrupted(self: *const Link) bool {
        if (hangup.load(.monotonic)) return true;
        const s = self.stopped orelse return false;
        return s.load(.monotonic);
    }
    fn hold(self: *Link, f: proto.Frame) !void {
        const payload = try self.gpa.dupe(u8, f.payload);
        errdefer self.gpa.free(payload);
        try self.held.append(self.gpa, .{ .kind = f.kind, .stream = f.stream, .payload = payload });
    }
    fn callFn(ptr: *anyopaque, arena: std.mem.Allocator, verb: []const u8, params: []const u8) anyerror!Reply {
        const self: *Link = @ptrCast(@alignCast(ptr));
        if (self.lost) return error.ConnectionLost;
        const id = self.next_id;
        self.next_id += 1;
        const verb_json = try std.json.Stringify.valueAlloc(self.gpa, verb, .{});
        defer self.gpa.free(verb_json);
        const body = try std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"verb\":{s},\"params\":{s}}}", .{ id, verb_json, params });
        defer self.gpa.free(body);
        try self.conn().sendMessage(.{ .ndjson = body });
        const start = nowMs();
        while (nowMs() - start < self.timeout_ms) {
            if (self.interrupted()) return error.Interrupted;
            const msg = try self.client.receive(50) orelse continue;
            if (msg != .frame) continue;
            const f = msg.frame;
            if (f.stream != 0 or f.kind != proto.Kind.control) {
                if (f.stream == 0 and (f.kind == proto.Kind.err or f.kind == proto.Kind.close)) {
                    self.lost = true;
                    return error.ConnectionLost;
                }
                try self.hold(f);
                continue;
            }
            var r = proto.Response.parse(self.gpa, f.payload) catch continue;
            defer r.deinit();
            const rid = if (r.id) |x| switch (x) {
                .integer => |i| i,
                else => continue,
            } else continue;
            if (rid != id) {
                try self.hold(f);
                continue;
            }
            return switch (r.body) {
                .ok => |v| .{ .ok = try clone(arena, v) },
                .@"error" => |e| .{ .err = try arena.dupe(u8, e.code) },
                .item => continue,
            };
        }
        return error.Timeout;
    }
};

fn clone(a: std.mem.Allocator, v: Value) !Value {
    const text = try std.json.Stringify.valueAlloc(a, v, .{});
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
}

/// The caller's environment plus `VENOMX_TOKEN=@owner` unless it has a
/// token: presentation clients use the owner file by default, as
/// `venomx attach` does. Null when the caller already has a token.
fn ownerEnviron(a: std.mem.Allocator, environ: std.process.Environ) !?std.process.Environ {
    if (environ.getPosix("VENOMX_TOKEN") != null) return null;
    const old = environ.block.view().slice;
    const slice = try a.allocSentinel(?[*:0]const u8, old.len + 1, null);
    for (old, 0..) |entry, i| slice[i] = entry;
    slice[old.len] = "VENOMX_TOKEN=@owner";
    return .{ .block = .{ .slice = slice } };
}

fn connect(ctx: Context, owner: ?std.process.Environ) !proto.Client {
    const caps = [_][]const u8{ "cancel", pane_stream.capability };
    var tries: [2]?std.process.Environ = .{ owner, null };
    const attempts: []const ?std.process.Environ = if (owner != null) &tries else tries[1..];
    var last: anyerror = error.ConnectFailed;
    for (attempts) |env| {
        var client = try proto.Client.init(ctx.gpa, .{
            .tool = "venomx",
            .path = .{ .environ = env orelse ctx.environ },
            .protocol = .binary,
            .hello = .{ .identity = .{ .name = "venom-desk", .version = "0.0.0" }, .caps = &caps },
        });
        const deadline = nowMs() + 10_000;
        const ok = blk: {
            while (true) {
                const done = client.pollHello(100) catch |err| {
                    // Inside a managed tree the owner token is refused; the
                    // pane's own rights apply instead.
                    if (err == error.DeniedToken and env != null and client.token_failure == .owner_context) break :blk false;
                    client.deinit();
                    return err;
                };
                if (done) break :blk true;
                if (ctx.stopped.load(.monotonic)) {
                    client.deinit();
                    return error.Interrupted;
                }
                if (nowMs() > deadline) {
                    client.deinit();
                    return error.Timeout;
                }
            }
        };
        if (ok) return client;
        client.deinit();
        last = error.DeniedToken;
    }
    return last;
}

fn connectFailure(err: anyerror) cli.Local.Failure {
    return switch (err) {
        error.NotRunning, error.ConnectFailed, error.Timeout, error.FileNotFound => .{ .code = "unavailable", .message = "no venomx daemon is listening (start one with `venomx`)" },
        error.DeniedToken => .{ .code = "denied", .message = "venomx refused the credentials" },
        error.Interrupted => .{ .code = "cancelled", .message = "interrupted" },
        else => .{ .code = "unavailable", .message = @errorName(err) },
    };
}

// ------------------------------------------------------------- the desk daemon

/// What the venom-desk daemon (when it runs) says about this session: its
/// tiling policy and the palette's products. Without one, the built-ins.
const DeskSettings = struct {
    policy: desk_mod.tiling.Policy = .bsp,
    products: []const []const u8 = &desk_mod.palette.default_products,
};
fn deskSettings(ctx: Context, a: std.mem.Allocator, path: proto.SocketOptions, session: []const u8) DeskSettings {
    var out: DeskSettings = .{};
    var wire = desk_mod.client.Wire.connect(ctx.gpa, .{ .tool = "venom-desk", .socket = path.socket, .environ = path.environ orelse ctx.environ, .connect_ms = 500 }) catch return out;
    defer wire.deinit();
    wire.timeout_ms = 2000;
    const c = wire.asClient();
    switch (c.call(a, "tiling.list", .{}) catch return out) {
        .ok => |v| {
            if (desk_mod.json.str(v, "default")) |p| out.policy = std.meta.stringToEnum(desk_mod.tiling.Policy, p) orelse out.policy;
            for (desk_mod.json.array(v, "sessions") orelse &.{}) |s| if (eq(u8, desk_mod.json.str(s, "session") orelse "", session)) {
                out.policy = std.meta.stringToEnum(desk_mod.tiling.Policy, desk_mod.json.str(s, "policy") orelse "") orelse out.policy;
            };
        },
        .err => {},
    }
    switch (c.call(a, "config.get", .{ .key = "palette" }) catch return out) {
        .ok => |v| if (desk_mod.json.str(v, "content")) |content| {
            const P = struct { products: []const []const u8 = &desk_mod.palette.default_products };
            if (desk_mod.status.parseConfig(P, a, content)) |p| {
                out.products = p.products;
            } else |_| {}
        },
        .err => {},
    }
    return out;
}

// ------------------------------------------------------------- entry

pub fn run(ctx: Context, local: cli.Local.Context) !cli.Local.Outcome {
    const session = local.params.object.get("session").?.string;
    const history: u64 = @intCast(local.params.object.get("history").?.integer);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const environ = local.path.environ orelse ctx.environ;
    const owner = try ownerEnviron(a, environ);
    var link: Link = .{ .gpa = ctx.gpa, .client = connect(ctx, owner) catch |err| return .{ .failure = connectFailure(err) }, .stopped = ctx.stopped };
    defer link.deinit();
    if (!link.conn().hasCap(pane_stream.capability)) return failure("unsupported", "the venomx daemon does not offer venomx.pane_stream");
    const c = link.asClient();
    // Failures before the UI are ordinary error objects.
    switch (c.call(a, "session.get", .{ .session = session }) catch |err| return .{ .failure = connectFailure(err) }) {
        .ok => {},
        .err => |code| {
            if (std.mem.startsWith(u8, code, "not_found")) return failure("not_found.session", "no such session");
            if (std.mem.startsWith(u8, code, "denied")) return failure("denied.read", "cannot read the session");
            return failure("failed", "session.get failed");
        },
    }
    const settings = deskSettings(ctx, a, local.path, session);
    const nested_pane = environ.getPosix("VENOMX_PANE");
    if (nested_pane) |p| {
        local.stderr.print("venom-desk: warning: running inside venomx pane {s}; this is a nested presentation client (its leader only works when the outer one passes it)\n", .{p}) catch {};
        local.stderr.flush() catch {};
    }

    var env_list: std.ArrayList([]const u8) = .empty;
    for (environ.block.view().slice) |entry| try env_list.append(a, std.mem.span(entry));
    var runner = exec.Runner.init(ctx.gpa, ctx.io);
    defer runner.deinit();
    const size = hostSize();
    var d = try Desk.init(ctx.gpa, c, .{
        .session = session,
        .cols = size.cols,
        .rows = size.rows,
        .policy = settings.policy,
        .shell = environ.getPosix("SHELL") orelse "/bin/sh",
        .nested = nested_pane != null,
        .exec = exec.Runner.hook,
        .exec_ctx = &runner,
        .environ = env_list.items,
    });
    defer d.deinit();
    d.now_ms = nowMs();
    // `{host}` and `{user}` in status templates, as venomx attach.
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    d.host = std.posix.gethostname(&host_buf) catch "";
    d.user = environ.getPosix("USER") orelse "";
    subscribeThenRefresh(&link, &d) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .failure = connectFailure(err) };
    };
    desk_mod.palette.discover(&d.palette, ctx.gpa, ctx.io, settings.products) catch {};

    var app: App = .{ .ctx = ctx, .link = &link, .d = &d, .runner = &runner, .history = history, .chrome = .{ .theme = &term.theme.trve, .edition = .venomx, .mode = term.theme.Mode.detect(ctx.environ_map) } };
    defer app.deinit();
    const result: anyerror!void = blk: {
        var tty = try Tty.enter();
        defer tty.leave();
        var surface = try Surface.init(ctx.gpa, size.cols, size.rows);
        var out_buf: [64 * 1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(ctx.io, &out_buf);
        const out = &stdout.interface;
        defer {
            surface.deinit(out);
            out.writeAll("\x1b[<u") catch {};
            out.writeAll(Tty.restore_sequence) catch {};
            out.flush() catch {};
        }
        try out.writeAll(Tty.enter_sequence);
        try out.flush();
        const r = app.loop(&surface, out);
        // A verb call cut short by a stop: leave as the loop would have.
        if (r) |_| {} else |err| if (err == error.Interrupted) break :blk app.leave();
        break :blk r;
    };
    if (result) |_| {} else |err| {
        if (err == error.ConnectionLost) return failure("unavailable", "lost the connection to venomx");
        return err;
    }
    if (d.detached) {
        local.stderr.print("[venom-desk: detached from {s}]\n", .{session}) catch {};
    } else if (d.ended) {
        local.stderr.print("[venom-desk: session {s} ended]\n", .{session}) catch {};
    }
    local.stderr.flush() catch {};
    return .{ .status = 0 };
}
const Surface = term.Surface;

/// Subscribe to `events` first, then fetch the settings `refresh` reads.
/// A `config.*` / `keys.*` change that lands between the two is
/// then an event item, held while `refresh` waits and replayed by the loop;
/// replaying it only fetches the same settings again. The other order would
/// lose such a change.
fn subscribeThenRefresh(link: *Link, d: *Desk) !void {
    try link.client.request(events_id, "events", .{ .types = desk_mod.desk.event_types });
    try d.refresh();
}

// ------------------------------------------------------------- the loop

const Entry = struct {
    stream: PaneStream,
    view: term.VtView = .{},
    /// When the server closed the stream; a still-shown pane re-attaches
    /// `reattach_ms` later.
    closed_at: i64 = 0,
};
/// How long a shown pane whose stream the server closed waits before it
/// attaches again: long enough not to spin on a refusal.
const reattach_ms = 1000;

const App = struct {
    ctx: Context,
    link: *Link,
    d: *Desk,
    runner: *exec.Runner,
    history: u64,
    chrome: term.theme.Chrome,
    streams: std.ArrayList(*Entry) = .empty,
    next_stream: u32 = 1,
    input: term.Input = .{},
    dirty: bool = true,
    /// Codepoints of pressed keys the desk consumed; their releases are
    /// swallowed too, so a pane never sees half a key.
    suppressed: std.ArrayList(u21) = .empty,
    paste: ?std.ArrayList(u8) = null,
    shown: []render.Shown = &.{},
    shown_arena: std.heap.ArenaAllocator = undefined,
    last_clock: i64 = 0,
    clock_buf: [8]u8 = undefined,

    fn deinit(self: *App) void {
        for (self.streams.items) |e| {
            e.stream.deinit();
            self.ctx.gpa.destroy(e);
        }
        self.streams.deinit(self.ctx.gpa);
        self.suppressed.deinit(self.ctx.gpa);
        if (self.paste) |*p| p.deinit(self.ctx.gpa);
    }

    fn find(self: *App, pane: []const u8) ?*Entry {
        for (self.streams.items) |e| if (eq(u8, e.stream.pane, pane)) return e;
        return null;
    }
    fn byId(self: *App, id: u32) ?*Entry {
        for (self.streams.items) |e| if (e.stream.id == id) return e;
        return null;
    }
    fn focused(self: *App) ?*Entry {
        return self.find(self.d.view.focus orelse return null);
    }

    fn loop(self: *App, surface: *Surface, out: *std.Io.Writer) !void {
        const gpa = self.ctx.gpa;
        self.shown_arena = .init(gpa);
        defer self.shown_arena.deinit();
        var in_buf: [8192]u8 = undefined;
        var in_len: usize = 0;
        var escape_deadline: ?i64 = null;
        var next_frame: i64 = 0;
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        var frame: std.Io.Writer.Allocating = .init(gpa);
        defer frame.deinit();
        while (true) {
            if (self.ctx.stopped.load(.monotonic) or hangup.load(.monotonic)) return self.leave();
            try self.pump();
            if (self.d.ended) return self.leave();
            const now = nowMs();
            if (try self.d.tick(now)) self.dirty = true;
            self.updateClock(now);
            self.runner.reap();
            try self.runner.report(self, reportFailure);
            try self.syncStreams();
            try self.drain();
            if (self.dirty and now >= next_frame) {
                _ = frame_arena.reset(.retain_capacity);
                try render.draw(self.d, frame_arena.allocator(), surface, self.chrome, .{ .ctx = self, .find = findStream, .view = findView });
                frame.clearRetainingCapacity();
                try surface.present(self.ctx.io, self.ctx.environ_map, &frame.writer);
                try out.writeAll(frame.written());
                try out.flush();
                self.dirty = false;
                next_frame = now + 16;
            }
            const conn = self.link.conn();
            var fds = [_]posix.pollfd{
                .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = conn.fd, .events = posix.POLL.IN | (if (conn.output.items.len > 0) posix.POLL.OUT else @as(i16, 0)), .revents = 0 },
                .{ .fd = winch_pipe[0], .events = posix.POLL.IN, .revents = 0 },
            };
            var timeout: i32 = if (self.dirty) @intCast(@max(1, next_frame - now)) else 250;
            if (escape_deadline) |deadline| timeout = @intCast(@min(timeout, @max(0, deadline - now)));
            // The popup's delay and `keys.timeout_ms`.
            if (self.d.nextWake()) |wake| timeout = @intCast(@min(timeout, @max(0, wake - now)));
            _ = posix.poll(&fds, timeout) catch |err| if (err != error.Interrupted) return err;
            if (fds[2].revents != 0) {
                var drop: [64]u8 = undefined;
                while (std.c.read(winch_pipe[0], &drop, drop.len) > 0) {}
                const sz = hostSize();
                self.d.options.cols = sz.cols;
                self.d.options.rows = sz.rows;
                try surface.resize(sz.cols, sz.rows);
                self.dirty = true;
            }
            if (fds[0].revents != 0) {
                const n = std.c.read(posix.STDIN_FILENO, in_buf[in_len..].ptr, in_buf.len - in_len);
                if (n == 0) return self.leave();
                if (n > 0) {
                    in_len += @intCast(n);
                    const used = try self.feed(in_buf[0..in_len]);
                    if (used > 0) escape_deadline = null;
                    std.mem.copyForwards(u8, in_buf[0 .. in_len - used], in_buf[used..in_len]);
                    in_len -= used;
                    if (in_len == in_buf.len) in_len = 0;
                    self.dirty = true;
                }
            }
            // A lone ESC may start a split key sequence: wait 25 ms for more.
            if (in_len == 1 and in_buf[0] == 0x1b and self.paste == null) {
                if (escape_deadline) |deadline| {
                    if (nowMs() >= deadline) {
                        try self.key(.{ .codepoint = 27, .text = null, .shifted = null, .base_layout = null, .mods = .{}, .action = .press });
                        in_len = 0;
                        escape_deadline = null;
                        self.dirty = true;
                    }
                } else escape_deadline = nowMs() + 25;
            } else escape_deadline = null;
            if (fds[1].revents & (posix.POLL.ERR | posix.POLL.NVAL | posix.POLL.HUP) != 0 and fds[1].revents & posix.POLL.IN == 0) return error.ConnectionLost;
        }
    }

    fn reportFailure(self: *App, f: exec.Failure) anyerror!void {
        self.dirty = true;
        if (f.spawn_error) |err| {
            try self.d.notice(.warn, "exec {s} could not start: {s}", .{ f.argv0, @errorName(err) });
        } else if (f.signaled) {
            try self.d.notice(.warn, "exec {s} killed by signal {d}", .{ f.argv0, f.status });
        } else try self.d.notice(.warn, "exec {s} exited {d}", .{ f.argv0, f.status });
    }

    /// Detach every stream and hand the CLOSE frames to the socket.
    fn leave(self: *App) !void {
        for (self.streams.items) |e| try e.stream.detach();
        try self.drain();
        const deadline = nowMs() + 200;
        while (self.link.conn().output.items.len > 0 and nowMs() < deadline) {
            _ = self.link.client.receive(10) catch break;
        }
    }

    fn updateClock(self: *App, now: i64) void {
        if (now - self.last_clock < 1000 and self.d.clock.len > 0) return;
        self.last_clock = now;
        var t: c_long = time(null);
        var tm: Tm = undefined;
        if (localtime_r(&t, &tm) == null) return;
        const text = std.fmt.bufPrint(&self.clock_buf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)) }) catch return;
        if (!eq(u8, text, self.d.clock)) self.dirty = true;
        self.d.clock = text;
        // `{clock:…}` in status templates, in local time.
        self.d.clock_now = desk_mod.status.template.Clock.fromEpoch(t, @intCast(tm.gmtoff));
    }

    // ---------------------------------------------------------- socket

    /// Everything that arrived: held frames first, then the socket.
    fn pump(self: *App) !void {
        while (self.link.held.items.len > 0) {
            const h = self.link.held.orderedRemove(0);
            defer self.ctx.gpa.free(h.payload);
            try self.dispatch(.{ .kind = h.kind, .stream = h.stream, .payload = h.payload });
        }
        while (true) {
            const msg = self.link.client.receive(0) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.ConnectionLost,
            } orelse break;
            if (msg != .frame) continue;
            // Copy: a verb call inside dispatch reads the connection again.
            const payload = try self.ctx.gpa.dupe(u8, msg.frame.payload);
            defer self.ctx.gpa.free(payload);
            try self.dispatch(.{ .kind = msg.frame.kind, .stream = msg.frame.stream, .payload = payload });
            if (self.d.ended) return;
        }
    }
    fn dispatch(self: *App, f: proto.Frame) !void {
        if (f.stream == 0) {
            if (f.kind == proto.Kind.err or f.kind == proto.Kind.close) return error.ConnectionLost;
            if (f.kind != proto.Kind.control) return;
            var r = proto.Response.parse(self.ctx.gpa, f.payload) catch return;
            defer r.deinit();
            const rid = if (r.id) |x| switch (x) {
                .integer => |i| i,
                else => return,
            } else return;
            if (rid != events_id) return;
            switch (r.body) {
                .item => |item| {
                    self.d.now_ms = nowMs();
                    self.d.handle(item) catch |err| if (err == error.OutOfMemory) return err;
                    self.dirty = true;
                },
                // The subscription ended or was refused: nothing more to show.
                .ok, .@"error" => return error.ConnectionLost,
            }
            return;
        }
        const e = self.byId(f.stream) orelse return;
        const before = e.stream.generation;
        const was_closed = e.stream.phase == .closed;
        e.stream.handle(f.kind, f.payload) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A malformed frame: start over with a fresh snapshot.
            else => e.stream.requestResync() catch {},
        };
        if (!was_closed and e.stream.phase == .closed) e.closed_at = nowMs();
        if (e.stream.generation != before) self.dirty = true;
    }
    /// Queue every stream's C→S frames, then drop the finished streams.
    fn drain(self: *App) !void {
        const conn = self.link.conn();
        for (self.streams.items) |e| try e.stream.flush(conn, sendFrame);
        self.prune(nowMs());
    }
    fn sendFrame(conn: *proto.Connection, stream: u32, o: pane_stream.Out) anyerror!void {
        try conn.sendMessage(.{ .frame = .{ .kind = o.kind, .stream = stream, .payload = o.payload } });
    }
    /// Drop closed streams whose frames are all out: ours ("detached"), and
    /// ones the server closed once their pane is no longer shown or has
    /// waited `reattach_ms`. `syncStreams` then attaches a shown pane again
    /// instead of `find` returning a dead stream forever.
    fn prune(self: *App, now: i64) void {
        var i: usize = 0;
        while (i < self.streams.items.len) {
            const e = self.streams.items[i];
            if (self.finished(e, now)) {
                e.stream.deinit();
                self.ctx.gpa.destroy(e);
                _ = self.streams.swapRemove(i);
                self.dirty = true;
                continue;
            }
            i += 1;
        }
    }
    fn finished(self: *App, e: *Entry, now: i64) bool {
        if (e.stream.phase != .closed or e.stream.outbox.items.len > 0) return false;
        if (e.stream.closed) |reason| if (eq(u8, reason, "detached")) return true;
        for (self.shown) |s| if (eq(u8, s.pane, e.stream.pane)) return now - e.closed_at >= reattach_ms;
        return true;
    }

    /// One stream per shown pane, sized to the cells it gets here.
    fn syncStreams(self: *App) !void {
        _ = self.shown_arena.reset(.retain_capacity);
        self.shown = try render.layout(self.d, self.shown_arena.allocator());
        for (self.shown) |s| {
            const size: pane_stream.Size = .{ .cols = @max(1, s.inner.width), .rows = @max(1, s.inner.height) };
            if (self.find(s.pane)) |e| {
                try e.stream.viewport(size);
                continue;
            }
            const e = try self.ctx.gpa.create(Entry);
            errdefer self.ctx.gpa.destroy(e);
            e.* = .{ .stream = try PaneStream.init(self.ctx.gpa, s.pane, self.next_stream, size, self.history) };
            errdefer e.stream.deinit();
            self.next_stream += 2;
            try e.stream.attach(null);
            try self.streams.append(self.ctx.gpa, e);
            self.dirty = true;
        }
        for (self.streams.items) |e| {
            if (e.stream.phase == .closed) continue;
            var still = false;
            for (self.shown) |s| still = still or eq(u8, s.pane, e.stream.pane);
            if (!still) try e.stream.detach();
        }
    }

    // ---------------------------------------------------------- input

    fn feed(self: *App, bytes: []const u8) !usize {
        var used: usize = 0;
        while (used < bytes.len and !self.d.ended) {
            const rest = bytes[used..];
            if (self.paste != null) {
                const end = "\x1b[201~";
                if (std.mem.indexOf(u8, rest, end)) |at| {
                    try self.paste.?.appendSlice(self.ctx.gpa, rest[0..at]);
                    try self.finishPaste();
                    used += at + end.len;
                    continue;
                }
                var suffix = @min(rest.len, end.len - 1);
                while (suffix > 0 and !std.mem.endsWith(u8, rest, end[0..suffix])) suffix -= 1;
                try self.paste.?.appendSlice(self.ctx.gpa, rest[0 .. rest.len - suffix]);
                used += rest.len - suffix;
                break;
            }
            if (rest.len == 1 and rest[0] == 0x1b) break;
            const result = self.input.parse(rest) catch {
                used += 1;
                continue;
            };
            if (result.consumed == 0) break;
            used += result.consumed;
            const ev = result.event orelse continue;
            switch (ev) {
                .key => |k| try self.key(k),
                .mouse => |m| try self.mouse(m),
                .paste_start => {
                    if (self.d.router.pending()) self.d.endLeader();
                    self.paste = .empty;
                },
                else => {},
            }
        }
        return used;
    }
    fn finishPaste(self: *App) !void {
        var p = self.paste.?;
        self.paste = null;
        defer p.deinit(self.ctx.gpa);
        // A paste never reaches the palette or a pane behind an overlay.
        if (self.d.view.overlay != .none) return;
        const e = self.focused() orelse return;
        const vt = e.stream.vt orelse return;
        const bracketed = (vt.inputModes() catch return).bracketed_paste;
        if (bracketed) try e.stream.input("\x1b[200~");
        try e.stream.input(p.items);
        if (bracketed) try e.stream.input("\x1b[201~");
    }

    fn isModifierKey(cp: u21) bool {
        return (cp >= 57358 and cp <= 57360) or (cp >= 57441 and cp <= 57454);
    }
    fn key(self: *App, k: term.Input.Key) !void {
        const gpa = self.ctx.gpa;
        if (k.action == .release) {
            for (self.suppressed.items, 0..) |cp, i| if (cp == k.codepoint) {
                _ = self.suppressed.swapRemove(i);
                return;
            };
            return self.sendKey(k);
        }
        if (k.action == .repeat) for (self.suppressed.items) |cp| if (cp == k.codepoint) return;
        // A host reporting every key sends Shift on its own; it must not
        // end a pending leader or reach the palette.
        if (isModifierKey(k.codepoint)) {
            if (self.d.router.pending() or self.d.view.overlay != .none) return;
            return self.sendKey(k);
        }
        const text = try keys.chordText(gpa, self.chord(k));
        defer gpa.free(text);
        const before = self.d.forwarded.items.len;
        self.d.now_ms = nowMs();
        try self.d.press(text);
        const passed = self.d.forwarded.items.len > before;
        for (self.d.forwarded.items) |f| gpa.free(f);
        self.d.forwarded.clearRetainingCapacity();
        if (!passed) {
            try self.suppressed.append(gpa, k.codepoint);
            if (self.suppressed.items.len > 32) _ = self.suppressed.orderedRemove(0);
            return;
        }
        // The key goes to the focused pane, encoded for that pane's modes.
        if (self.d.view.focus) |f| self.d.scrollBy(f, -std.math.maxInt(i32)) catch {};
        try self.sendKey(k);
    }
    /// The chord `Desk.press` gets. The open palette takes text, so it keeps the
    /// layout's character; the router's tables are in Latin (`Router.chordOf`).
    fn chord(self: *const App, k: term.Input.Key) keys.Chord {
        const mods: keys.Mods = .{ .ctrl = k.mods.ctrl, .alt = k.mods.alt, .shift = k.mods.shift, .super = k.mods.super };
        if (self.d.view.overlay == .palette and !self.d.router.pending()) return keys.fromKey(k.codepoint, mods, k.shifted, k.text);
        return self.d.router.chordOf(self.d.keymap.settings, k.codepoint, mods, k.shifted, k.text, k.base_layout);
    }
    fn sendKey(self: *App, k: term.Input.Key) !void {
        const e = self.focused() orelse return;
        const vt = e.stream.vt orelse return;
        const bytes = vt.encodeKey(self.ctx.gpa, k) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer self.ctx.gpa.free(bytes);
        try e.stream.input(bytes);
    }
    fn mouse(self: *App, m: term.Input.Mouse) !void {
        // Like a paste, the mouse never reaches the panes behind an overlay,
        // and a click there must not move focus under it.
        if (self.d.view.overlay != .none) return;
        if (m.x < 0 or m.y < 0) return;
        const x: u16 = @intCast(m.x);
        const y: u16 = @intCast(m.y);
        // A left click on the status line or the rail runs the
        // segment's target as this client; nothing there reaches a pane.
        if (self.d.onChrome(x, y)) {
            if (m.action == .press and m.button == .left) {
                self.d.now_ms = nowMs();
                _ = try self.d.click(x, y);
                self.dirty = true;
            }
            return;
        }
        const s = render.hit(self.shown, x, y) orelse return;
        const e = self.find(s.pane);
        const tracking = if (e) |en| if (en.stream.vt) |vt| (vt.inputModes() catch null) else null else null;
        const inside = x >= s.inner.x and y >= s.inner.y and x < s.inner.x + s.inner.width and y < s.inner.y + s.inner.height;
        if (m.action == .press and m.button == .left) {
            self.d.now_ms = nowMs();
            try self.d.focus(s.pane);
            self.dirty = true;
        }
        // A pane that tracks the mouse gets it, in its own cell coordinates.
        if (inside and tracking != null and tracking.?.mouse_tracking) {
            var local = m;
            local.x -= @intCast(s.inner.x);
            local.y -= @intCast(s.inner.y);
            const vt = e.?.stream.vt.?;
            const bytes = vt.encodeMouse(self.ctx.gpa, local, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
            defer self.ctx.gpa.free(bytes);
            return e.?.stream.input(bytes);
        }
        switch (m.button) {
            .wheel_up => try self.d.scrollBy(s.pane, 3),
            .wheel_down => try self.d.scrollBy(s.pane, -3),
            else => return,
        }
        self.dirty = true;
    }
};

fn findStream(ctx: *anyopaque, pane: []const u8) ?*PaneStream {
    const self: *App = @ptrCast(@alignCast(ctx));
    const e = self.find(pane) orelse return null;
    return &e.stream;
}
fn findView(ctx: *anyopaque, pane: []const u8) ?*term.VtView {
    const self: *App = @ptrCast(@alignCast(ctx));
    const e = self.find(pane) orelse return null;
    return &e.view;
}

// ------------------------------------------------------------- the host tty

/// libc's local time, for the `venomx.clock` segment (as `venomx attach`).
const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;

var winch_pipe: [2]posix.fd_t = .{ -1, -1 };

/// SIGHUP (the host terminal went away) stops the loop like SIGTERM/SIGINT,
/// so the terminal is restored instead of left raw by the default action.
/// venom-std's `installSignalHandlers` covers only TERM and INT,
/// so attach handles HUP itself while the terminal is raw.
var hangup: std.atomic.Value(bool) = .init(false);
fn onHangup(_: posix.SIG) callconv(.c) void {
    hangup.store(true, .release);
}
fn catchHangup() void {
    var act: posix.Sigaction = .{ .handler = .{ .handler = onHangup }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.HUP, &act, null);
}
fn releaseHangup() void {
    var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.HUP, &act, null);
}
fn onWinch(_: posix.SIG) callconv(.c) void {
    const byte = [_]u8{1};
    _ = std.c.write(winch_pipe[1], &byte, 1);
}

const Tty = struct {
    saved: posix.termios,
    // Alternate screen, all-motion SGR mouse, bracketed paste and Kitty
    // keyboard flags 31 (legacy hosts ignore what they do not support).
    const enter_sequence = "\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[>31u";
    const restore_sequence = "\x1b[?2026l\x1b[?2004l\x1b[?1004l\x1b[?1000l\x1b[?1003l\x1b[?1016l\x1b[>4;0m\x1b[r\x1b[?1006l\x1b[?1002l\x1b[0m\x1b[?25h\x1b[?1049l";
    fn enter() !Tty {
        if (std.c.pipe2(&winch_pipe, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return error.PipeFailed;
        var act: posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART };
        posix.sigaction(.WINCH, &act, null);
        catchHangup();
        errdefer releaseHangup();
        const saved = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = saved;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        // NOW keeps typeahead queued for the pane.
        try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
        return .{ .saved = saved };
    }
    fn leave(self: *Tty) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
        var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.WINCH, &act, null);
        releaseHangup();
        for (winch_pipe) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        winch_pipe = .{ -1, -1 };
    }
};

fn ioctlRequest(comptime value: anytype) c_int {
    return @bitCast(@as(u32, @intCast(value)));
}
fn hostSize() struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(posix.STDOUT_FILENO, ioctlRequest(posix.T.IOCGWINSZ), @intFromPtr(&ws)) != 0 or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row };
}

// ------------------------------------------------------------- tests

const testing = std.testing;

/// A `Link` on one end of a socketpair; the test plays venomx on the other.
const Wire = struct {
    link: Link,
    server: proto.Connection,

    fn init(stopped: ?*const std.atomic.Value(bool)) !Wire {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.NONBLOCK | std.c.SOCK.CLOEXEC, 0, &fds) != 0) return error.SystemResources;
        var conn = proto.Connection.init(testing.allocator, fds[0]);
        conn.protocol = .binary;
        conn.ready = true;
        var server = proto.Connection.init(testing.allocator, fds[1]);
        server.protocol = .binary;
        const client: proto.Client = .{ .connection = conn, .options = .{ .tool = "venomx", .hello = .{ .identity = .{ .name = "venom-desk", .version = "0.0.0" } } } };
        return .{ .link = .{ .gpa = testing.allocator, .client = client, .stopped = stopped, .timeout_ms = 2000 }, .server = server };
    }
    fn deinit(self: *Wire) void {
        self.link.deinit();
        self.server.deinit();
    }
    /// One CONTROL line from venomx.
    fn send(self: *Wire, line: []const u8) !void {
        try self.server.sendMessage(.{ .ndjson = line });
        while (self.server.output.items.len > 0) try self.server.flush();
    }
    fn refuse(self: *Wire, id: i64) !void {
        var buf: [128]u8 = undefined;
        try self.send(try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"error\":{{\"code\":\"not_found.key\",\"message\":\"none\"}}}}", .{id}));
    }
    /// The verbs the client sent so far, in order.
    fn verbs(self: *Wire, a: std.mem.Allocator) ![]const []const u8 {
        // Requests queue until a receive polls; push out what is left.
        const conn = self.link.conn();
        while (conn.output.items.len > 0) try conn.flush();
        while (try self.server.read()) {}
        var out: std.ArrayList([]const u8) = .empty;
        while (try self.server.next()) |msg| {
            const v = try std.json.parseFromSliceLeaky(Value, a, msg.frame.payload, .{ .allocate = .alloc_always });
            try out.append(a, desk_mod.json.str(v, "verb") orelse "");
        }
        return out.items;
    }
};

test "attach subscribes to events before it fetches settings, and a replayed change is harmless" {
    var w = try Wire.init(null);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A config change lands while `refresh` waits on its first call; then
    // venomx answers its three calls (ids 10..12).
    try w.send("{\"id\":2,\"item\":{\"type\":\"config.changed\",\"data\":{\"key\":\"status\"}}}");
    for (10..13) |id| try w.refuse(@intCast(id));
    var d = try Desk.init(testing.allocator, w.link.asClient(), .{ .session = "s0" });
    defer d.deinit();
    try subscribeThenRefresh(&w.link, &d);
    const sent = try w.verbs(arena.allocator());
    try testing.expectEqual(@as(usize, 4), sent.len);
    try testing.expectEqualStrings("events", sent[0]);
    try testing.expectEqualStrings("config.get", sent[1]);
    try testing.expectEqualStrings("keys.list", sent[3]);
    // The change was held for the loop, not lost.
    try testing.expectEqual(@as(usize, 1), w.link.held.items.len);
    // Replaying it only fetches the same settings again.
    for (13..16) |id| try w.refuse(@intCast(id));
    var r = try proto.Response.parse(testing.allocator, w.link.held.items[0].payload);
    defer r.deinit();
    try d.handle(r.body.item);
    const again = try w.verbs(arena.allocator());
    try testing.expectEqual(@as(usize, 3), again.len);
    try testing.expectEqualStrings("config.get", again[0]);
    try testing.expectEqualStrings("keys.list", again[2]);
}

test "a verb call stops waiting once stopped is set" {
    var stopped = std.atomic.Value(bool).init(true);
    var w = try Wire.init(&stopped);
    defer w.deinit();
    w.link.timeout_ms = 10_000;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const began = nowMs();
    try testing.expectError(error.Interrupted, w.link.asClient().call(arena.allocator(), "session.get", .{ .session = "s0" }));
    try testing.expect(nowMs() - began < 1000);
}

fn testApp(d: *Desk, stopped: *const std.atomic.Value(bool)) App {
    return .{
        .ctx = .{ .gpa = testing.allocator, .io = testing.io, .environ = .empty, .environ_map = undefined, .stopped = stopped },
        .link = undefined,
        .d = d,
        .runner = undefined,
        .history = 0,
        .chrome = undefined,
    };
}
fn testEntry(app: *App, pane: []const u8, id: u32) !*Entry {
    const e = try testing.allocator.create(Entry);
    errdefer testing.allocator.destroy(e);
    e.* = .{ .stream = try PaneStream.init(testing.allocator, pane, id, .{ .cols = 10, .rows = 3 }, 0) };
    errdefer e.stream.deinit();
    try app.streams.append(testing.allocator, e);
    return e;
}
fn shownAt(pane: []const u8, x: u16) render.Shown {
    const r: desk_mod.floats.Rect = .{ .x = x, .y = 0, .width = 10, .height = 5 };
    return .{ .pane = pane, .rect = r, .inner = r, .border = .none, .float = false };
}

test "streams the server closed are dropped so their panes attach again" {
    var fake = desk_mod.client.Fake.init(testing.allocator);
    defer fake.deinit();
    var d = try Desk.init(testing.allocator, fake.client(), .{ .session = "s0" });
    defer d.deinit();
    const stopped = std.atomic.Value(bool).init(false);
    var app = testApp(&d, &stopped);
    defer app.deinit();
    var shown = [_]render.Shown{ shownAt("p0", 0), shownAt("p1", 10) };
    app.shown = shown[0..1];
    // p0 is shown, p1 is not; the server closed both, p2 is still live.
    const p0 = try testEntry(&app, "p0", 1);
    const p1 = try testEntry(&app, "p1", 3);
    _ = try testEntry(&app, "p2", 5);
    try p0.stream.handle(pane_stream.Kind.close, "{\"reason\":\"lagged\"}");
    try p1.stream.handle(pane_stream.Kind.close, "{\"reason\":\"lagged\"}");
    p0.closed_at = 100;
    p1.closed_at = 100;
    app.prune(100);
    // The hidden one goes at once; the shown one waits out `reattach_ms`.
    try testing.expectEqual(@as(usize, 2), app.streams.items.len);
    try testing.expect(app.find("p1") == null);
    try testing.expect(app.find("p0") != null);
    app.prune(100 + reattach_ms);
    try testing.expect(app.find("p0") == null);
    try testing.expect(app.find("p2") != null);
}

test "a click behind an overlay does not move focus" {
    var fake = desk_mod.client.Fake.init(testing.allocator);
    defer fake.deinit();
    var d = try Desk.init(testing.allocator, fake.client(), .{ .session = "s0" });
    defer d.deinit();
    const stopped = std.atomic.Value(bool).init(false);
    var app = testApp(&d, &stopped);
    defer app.deinit();
    var shown = [_]render.Shown{ shownAt("p0", 0), shownAt("p1", 10) };
    app.shown = &shown;
    try d.focus("p0");
    const click: term.Input.Mouse = .{ .x = 12, .y = 2, .button = .left, .action = .press, .mods = .{} };
    d.view.overlay = .palette;
    try app.mouse(click);
    try testing.expectEqualStrings("p0", d.view.focus.?);
    d.view.overlay = .none;
    try app.mouse(click);
    try testing.expectEqualStrings("p1", d.view.focus.?);
}

test "a non-Latin layout reaches the leader and unlock by the Latin key; the palette keeps its text" {
    var fake = desk_mod.client.Fake.init(testing.allocator);
    defer fake.deinit();
    var d = try Desk.init(testing.allocator, fake.client(), .{ .session = "s0" });
    defer d.deinit();
    const stopped = std.atomic.Value(bool).init(false);
    var app = testApp(&d, &stopped);
    defer app.deinit();
    d.keymap.settings.leader = keys.parseChord("ctrl+a").?;
    d.keymap.settings.unlock = keys.parseChord("ctrl+alt+a").?;
    const ctrl: term.Input.Modifiers = .{ .ctrl = true };
    const ctrl_alt: term.Input.Modifiers = .{ .ctrl = true, .alt = true };
    // CSI 945::97;5u: ctrl+α on the A key.
    const leader: term.Input.Key = .{ .codepoint = 945, .text = null, .shifted = null, .base_layout = 'a', .mods = ctrl, .action = .press };
    try app.key(leader);
    try testing.expect(d.router.pending());
    try app.key(.{ .codepoint = 27, .text = null, .shifted = null, .base_layout = null, .mods = .{}, .action = .press });
    try testing.expect(!d.router.pending());
    // Another Greek key is no leader.
    try app.key(.{ .codepoint = 946, .text = null, .shifted = null, .base_layout = 'b', .mods = ctrl, .action = .press });
    try testing.expect(!d.router.pending());
    // Lock mode ends on ctrl+alt+α.
    d.router.lock();
    try app.key(leader);
    try testing.expect(d.router.locked());
    try app.key(.{ .codepoint = 945, .text = null, .shifted = null, .base_layout = 'a', .mods = ctrl_alt, .action = .press });
    try testing.expect(!d.router.locked());
    // The palette gets the character typed, not the key it is on.
    d.view.overlay = .palette;
    try app.key(.{ .codepoint = 945, .text = "α", .shifted = null, .base_layout = 'a', .mods = .{}, .action = .press });
    try testing.expectEqualStrings("α", d.input.query.items);
}

test "SIGHUP sets the hangup flag instead of killing the client" {
    hangup.store(false, .monotonic);
    catchHangup();
    defer {
        releaseHangup();
        hangup.store(false, .monotonic);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.raise(.HUP));
    try testing.expect(hangup.load(.acquire));
    var w = try Wire.init(null);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Interrupted, w.link.asClient().call(arena.allocator(), "session.get", .{ .session = "s0" }));
}
