//! venom-desk: the agent contract's one binary. `verbs.zon` plus
//! venom-std's shared bundles (config, events, grants, skill, doctor)
//! generate the CLI, the MCP server (`venom-desk mcp`), the docs and the
//! completions.
//!
//! * `venom-desk serve`: the daemon (daemon.zig): tiling overrides, palette.
//! * `venom-desk attach --session <s>`: the full-screen presentation client
//!   (term/attach.zig), an interactive local command.
//! * `venom-desk tile split`, `workspace list|create`: desk actions that
//!   change venomx, run here with the caller's own venomx identity.
const std = @import("std");
const cli = @import("cli");
const proto = @import("proto");
const supervisor = @import("supervisor");
const desk = @import("venom-desk");
const daemon = @import("daemon.zig");
const attach = @import("term/attach.zig");

pub const App = daemon.App;
/// The renderer's debug logs would write over the screen.
pub const std_options: std.Options = .{ .log_scope_levels = &.{.{ .scope = .vaxis, .level = .warn }} };

const Local = struct {
    pub const commands = .{ "attach", "tile.split", "workspace.list", "workspace.create" };
    ctx: attach.Context,

    pub fn call(self: *Local, ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
        var c = self.ctx;
        if (ctx.interrupted) |i| c.stopped = i;
        if (std.mem.eql(u8, ctx.name, "attach")) return attach.run(c, ctx);
        const environ = ctx.path.environ orelse c.environ;
        // The caller's own venomx identity: never the owner file, never the
        // venom-desk daemon's rights.
        var wire = desk.client.Wire.connect(c.gpa, .{ .environ = environ, .connect_ms = 5000 }) catch |err| return .{ .failure = switch (err) {
            error.DeniedToken => .{ .code = "denied", .message = "venomx refused the credentials" },
            else => .{ .code = "unavailable", .message = "no venomx daemon is listening (start one with `venomx`)" },
        } };
        defer wire.deinit();
        const client = wire.asClient();
        const a = ctx.allocator;
        const shell = environ.getPosix("SHELL") orelse "/bin/sh";
        if (std.mem.eql(u8, ctx.name, "workspace.list")) {
            const list = desk.desk.listWorkspaces(a, client) catch |err| {
                if (err == error.OutOfMemory) return err;
                return venomxFailed(a, "session.list");
            };
            return result(a, .{ .workspaces = list });
        }
        if (std.mem.eql(u8, ctx.name, "workspace.create")) {
            const name = ctx.params.object.get("name").?.string;
            const argv = try argvParam(a, ctx.params, shell);
            const session = desk.desk.createWorkspace(a, client, name, argv) catch |err| {
                if (err == error.OutOfMemory) return err;
                return venomxFailed(a, @errorName(err));
            };
            return result(a, .{ .session = session, .name = name });
        }
        return tileSplit(a, client, ctx, environ, shell);
    }

    fn tileSplit(a: std.mem.Allocator, client: desk.client.Client, ctx: cli.Local.Context, environ: std.process.Environ, shell: []const u8) !cli.Local.Outcome {
        const p = ctx.params.object;
        const window = p.get("window").?.string;
        const got = switch (try client.call(a, "window.get", .{ .window = window })) {
            .ok => |v| v,
            .err => |code| {
                if (std.mem.startsWith(u8, code, "not_found")) return .{ .failure = .{ .code = "not_found.window", .message = "no such window" } };
                return venomxFailed(a, code);
            },
        };
        // Mirror the one window through the same parser the client uses.
        var state = desk.shared.State.init(a);
        const entity = try entityJson(a, got);
        _ = state.apply(entity, 0) catch return .{ .failure = .{ .code = "failed.venomx", .message = "venomx returned a window venom-desk cannot read" } };
        const w = state.window(window) orelse return .{ .failure = .{ .code = "not_found.window", .message = "no such window" } };
        const policy: desk.tiling.Policy = if (p.get("policy")) |v| std.meta.stringToEnum(desk.tiling.Policy, v.string).? else daemonPolicy(a, ctx, environ, w.session);
        const area: desk.floats.Rect = .{ .width = @intCast(p.get("cols").?.integer), .height = @intCast(p.get("rows").?.integer) };
        const focus = if (p.get("pane")) |v| v.string else null;
        if (focus) |f| if (!w.contains(f)) return .{ .failure = .{ .code = "invalid_params.pane", .message = "the pane is not a tile of the window" } };
        const plan = try desk.tiling.plan(a, policy, w.nodes, focus, area) orelse return .{ .failure = .{ .code = "conflict.empty_window", .message = "the window has no tiled pane to split" } };
        // The workspace is the session; its name tags the new pane.
        const workspace = switch (try client.call(a, "session.get", .{ .session = w.session })) {
            .ok => |v| desk.json.str(v, "name") orelse w.session,
            .err => w.session,
        };
        const argv = try argvParam(a, ctx.params, shell);
        const r = try client.call(a, "pane.split", .{ .pane = plan.pane, .axis = @tagName(plan.axis), .argv = argv, .tags = [_]desk.desk.TagPair{.{ .key = desk.desk.workspace_tag, .value = workspace }} });
        switch (r) {
            .ok => |v| return result(a, .{ .pane = desk.json.str(v, "pane") orelse "", .split = plan.pane, .axis = @tagName(plan.axis), .policy = @tagName(policy) }),
            .err => |code| return venomxFailed(a, code),
        }
    }
};

/// A `window.get` result (`{window, session, name, revision, nodes}`) as a
/// `window.created` event, so the client's own `shared.State` reads it.
fn entityJson(a: std.mem.Allocator, got: std.json.Value) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "type", .{ .string = "window.created" });
    try obj.put(a, "data", got);
    return .{ .object = obj };
}

fn daemonPolicy(a: std.mem.Allocator, ctx: cli.Local.Context, environ: std.process.Environ, session: []const u8) desk.tiling.Policy {
    var wire = desk.client.Wire.connect(a, .{ .tool = "venom-desk", .socket = ctx.path.socket, .environ = environ, .connect_ms = 500 }) catch return .bsp;
    defer wire.deinit();
    wire.timeout_ms = 2000;
    const v = switch (wire.asClient().call(a, "tiling.list", .{}) catch return .bsp) {
        .ok => |v| v,
        .err => return .bsp,
    };
    var policy = std.meta.stringToEnum(desk.tiling.Policy, desk.json.str(v, "default") orelse "") orelse .bsp;
    for (desk.json.array(v, "sessions") orelse &.{}) |s| if (std.mem.eql(u8, desk.json.str(s, "session") orelse "", session)) {
        policy = std.meta.stringToEnum(desk.tiling.Policy, desk.json.str(s, "policy") orelse "") orelse policy;
    };
    return policy;
}

fn argvParam(a: std.mem.Allocator, params: std.json.Value, shell: []const u8) ![]const []const u8 {
    const v = params.object.get("argv") orelse return a.dupe([]const u8, &.{shell});
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| try out.append(a, item.string);
    if (out.items.len == 0) try out.append(a, shell);
    return out.items;
}

fn result(a: std.mem.Allocator, value: anytype) !cli.Local.Outcome {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    return .{ .result = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) };
}
fn venomxFailed(a: std.mem.Allocator, code: []const u8) !cli.Local.Outcome {
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "code", .{ .string = code });
    return .{ .failure = .{ .code = "failed.venomx", .message = "venomx refused the request", .data = .{ .object = o } } };
}

pub fn main(init: std.process.Init) !void {
    const stopped = supervisor.installSignalHandlers();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    var d: daemon.Daemon = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .stderr = &err.interface, .stopped = stopped };
    var local: Local = .{ .ctx = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .environ_map = init.environ_map, .stopped = stopped } };
    const status = try App.run(init.gpa, argv[1..], .{
        .stdout = &out.interface,
        .stderr = &err.interface,
        .environ = init.minimal.environ,
        .bootstrap = cli.Bootstrap.init(&d),
        .local = cli.Local.init(&local),
        .interrupted = stopped,
    });
    try out.interface.flush();
    try err.interface.flush();
    if (status != 0) std.process.exit(status);
}

test {
    _ = daemon;
    _ = @import("term/pane_stream.zig");
    _ = @import("term/exec.zig");
    _ = @import("term/render.zig");
    _ = attach;
}

const t = std.testing;

fn runCli(args: []const []const u8, out: *std.Io.Writer.Allocating, err: *std.Io.Writer.Allocating) !u8 {
    var flag = std.atomic.Value(bool).init(false);
    var map = std.process.Environ.Map.init(t.allocator);
    defer map.deinit();
    var local: Local = .{ .ctx = .{ .gpa = t.allocator, .io = t.io, .environ = .empty, .environ_map = &map, .stopped = &flag } };
    return App.run(t.allocator, args, .{ .stdout = &out.writer, .stderr = &err.writer, .local = cli.Local.init(&local), .stdin = @as(std.c.fd_t, -1), .stdout_fd = @as(std.c.fd_t, -1) });
}

test "attach refuses to run without a terminal" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    try t.expectEqual(@as(u8, 10), try runCli(&.{ "attach", "--session=s0", "--json" }, &out, &err));
    try t.expect(std.mem.indexOf(u8, out.written(), "unsupported.terminal") != null);
}

test "generated docs and skill: local commands documented, attach left out of the skill" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try cli.docs.writeMarkdown(App, &out.writer);
    const skill = try cli.skill.render(App, arena.allocator(), daemon.skill_notes);
    for ([_][]const u8{ "`venom-desk attach`", "`venom-desk tile split`", "`venom-desk workspace list`", "`venom-desk workspace create`", "`venom-desk tiling list`", "`venom-desk tiling set`", "`venom-desk palette list`", "`venom-desk doctor`" }) |cmd| {
        try t.expect(std.mem.indexOf(u8, out.written(), cmd) != null);
    }
    for ([_][]const u8{ "`venom-desk tile split`", "`venom-desk tiling set`", "`venom-desk palette list`" }) |cmd| try t.expect(std.mem.indexOf(u8, skill, cmd) != null);
    try t.expect(std.mem.indexOf(u8, skill, "`venom-desk attach`") == null);
    try t.expect(App.schema.find("attach") == null and App.schema.find("tiling.set") != null);
}

test "window.get replies become a window the tiling policy can plan" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"main\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}", .{});
    var state = desk.shared.State.init(a);
    _ = try state.apply(try entityJson(a, got), 0);
    const w = state.window("w0").?;
    const plan = (try desk.tiling.plan(a, .bsp, w.nodes, null, .{ .width = 80, .height = 24 })).?;
    try t.expectEqualStrings("p0", plan.pane);
}
