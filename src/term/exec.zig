//! `exec` binding targets, run by this presentation client:
//! the argv directly (no shell), stdin from the null device, output
//! discarded, and the environment from `keys.execEnviron` (no venomx token,
//! principal or credential-looking value). A child that exits non-zero, or
//! that cannot start, is reported back as a client-local notification.
const std = @import("std");

pub const Failure = struct {
    /// Owned by the runner's allocator; free with `deinit`.
    argv0: []u8,
    /// Exit status, or the signal number when `signaled`.
    status: u32,
    signaled: bool,
    /// The child never ran (spawn failed); `status` is 0.
    spawn_error: ?anyerror = null,
    pub fn deinit(self: Failure, a: std.mem.Allocator) void {
        a.free(self.argv0);
    }
};

pub const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    children: std.ArrayList(Child) = .empty,
    /// Failures not yet reported, oldest first.
    failures: std.ArrayList(Failure) = .empty,

    const Child = struct { pid: std.posix.pid_t, argv0: []u8 };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Runner {
        return .{ .gpa = gpa, .io = io };
    }
    pub fn deinit(self: *Runner) void {
        for (self.children.items) |c| self.gpa.free(c.argv0);
        self.children.deinit(self.gpa);
        for (self.failures.items) |f| f.deinit(self.gpa);
        self.failures.deinit(self.gpa);
    }

    /// Hand each pending failure to `report`, oldest first. A failure leaves
    /// the list before it is freed, so when `report` fails the runner still
    /// owns exactly the ones not yet reported.
    pub fn report(self: *Runner, ctx: anytype, comptime f: fn (@TypeOf(ctx), Failure) anyerror!void) !void {
        while (self.failures.items.len > 0) {
            const pending = self.failures.orderedRemove(0);
            defer pending.deinit(self.gpa);
            try f(ctx, pending);
        }
    }

    /// `desk.Options.exec`: `ctx` is a `*Runner`; `env` is `NAME=value`.
    pub fn hook(ctx: ?*anyopaque, argv: []const []const u8, env: []const []const u8) void {
        const self: *Runner = @ptrCast(@alignCast(ctx.?));
        self.run(argv, env) catch |err| self.fail(argv, 0, false, err);
    }

    pub fn run(self: *Runner, argv: []const []const u8, env: []const []const u8) !void {
        if (argv.len == 0) return error.EmptyArgv;
        var map = std.process.Environ.Map.init(self.gpa);
        defer map.deinit();
        for (env) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            try map.put(entry[0..eq], entry[eq + 1 ..]);
        }
        // pgid 0: its own process group, so a keyboard signal aimed at
        // this client never reaches it.
        const child = try std.process.spawn(self.io, .{ .argv = argv, .environ_map = &map, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
        const pid = child.id orelse return error.SpawnFailed;
        const name = try self.gpa.dupe(u8, argv[0]);
        errdefer self.gpa.free(name);
        try self.children.append(self.gpa, .{ .pid = pid, .argv0 = name });
    }
    fn fail(self: *Runner, argv: []const []const u8, status: u32, signaled: bool, err: ?anyerror) void {
        const name = self.gpa.dupe(u8, if (argv.len > 0) argv[0] else "exec") catch return;
        self.failures.append(self.gpa, .{ .argv0 = name, .status = status, .signaled = signaled, .spawn_error = err }) catch self.gpa.free(name);
    }

    /// Reap exited children without blocking; non-zero exits become
    /// failures. Call once per loop turn.
    pub fn reap(self: *Runner) void {
        var i: usize = 0;
        while (i < self.children.items.len) {
            var status: c_int = 0;
            const n = std.c.waitpid(self.children.items[i].pid, &status, std.c.W.NOHANG);
            if (n == 0) {
                i += 1;
                continue;
            }
            const c = self.children.swapRemove(i);
            defer self.gpa.free(c.argv0);
            if (n < 0) continue;
            const s: u32 = @bitCast(status);
            if (std.posix.W.IFSIGNALED(s)) {
                self.fail(&.{c.argv0}, @backingInt(std.posix.W.TERMSIG(s)), true, null);
            } else if (std.posix.W.EXITSTATUS(s) != 0) {
                self.fail(&.{c.argv0}, std.posix.W.EXITSTATUS(s), false, null);
            }
        }
    }
};

const t = std.testing;

fn waitAll(r: *Runner) !void {
    var tries: usize = 0;
    while (r.children.items.len > 0) : (tries += 1) {
        if (tries > 500) return error.Timeout;
        r.reap();
        var none = [_]std.posix.pollfd{};
        _ = std.posix.poll(&none, 10) catch {};
    }
}

test "exec: success is silent, a non-zero exit and a missing binary are reported" {
    var r = Runner.init(t.allocator, t.io);
    defer r.deinit();
    try r.run(&.{ "/bin/sh", "-c", "exit 0" }, &.{"PATH=/bin:/usr/bin"});
    try r.run(&.{ "/bin/sh", "-c", "exit 3" }, &.{"PATH=/bin:/usr/bin"});
    Runner.hook(&r, &.{"/nonexistent/venom-desk-test"}, &.{});
    try waitAll(&r);
    try t.expectEqual(@as(usize, 2), r.failures.items.len);
    var saw_exit = false;
    var saw_spawn = false;
    for (r.failures.items) |f| {
        if (f.spawn_error != null) saw_spawn = true;
        if (f.spawn_error == null and f.status == 3 and !f.signaled) saw_exit = true;
    }
    try t.expect(saw_exit and saw_spawn);
}

test "exec: the child sees only the environment it was given" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const out = try std.fmt.allocPrint(t.allocator, "{s}/env", .{dir});
    defer t.allocator.free(out);
    const script = try std.fmt.allocPrint(t.allocator, "env > '{s}'", .{out});
    defer t.allocator.free(script);
    var r = Runner.init(t.allocator, t.io);
    defer r.deinit();
    try r.run(&.{ "/bin/sh", "-c", script }, &.{ "PATH=/bin:/usr/bin", "ONLY=1" });
    try waitAll(&r);
    try t.expectEqual(@as(usize, 0), r.failures.items.len);
    const got = try std.Io.Dir.cwd().readFileAlloc(t.io, out, t.allocator, .limited(1 << 16));
    defer t.allocator.free(got);
    try t.expect(std.mem.indexOf(u8, got, "ONLY=1") != null);
    try t.expect(std.mem.indexOf(u8, got, "VENOMX_TOKEN") == null);
}

test "exec: a failing report frees each failure once" {
    var r = Runner.init(t.allocator, t.io);
    defer r.deinit();
    for ([_][]const u8{ "a", "b", "c" }) |name| try r.failures.append(t.allocator, .{ .argv0 = try t.allocator.dupe(u8, name), .status = 1, .signaled = false });
    const Sink = struct {
        seen: usize = 0,
        fn f(self: *@This(), fail: Failure) anyerror!void {
            self.seen += 1;
            if (std.mem.eql(u8, fail.argv0, "b")) return error.OutOfMemory;
        }
    };
    var sink: Sink = .{};
    try t.expectError(error.OutOfMemory, r.report(&sink, Sink.f));
    try t.expectEqual(@as(usize, 2), sink.seen);
    try t.expectEqual(@as(usize, 1), r.failures.items.len);
    try t.expectEqualStrings("c", r.failures.items[0].argv0);
}
