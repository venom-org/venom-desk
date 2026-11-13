//! The venom-desk daemon (daemon and CLI are one binary).
//!
//! `venom-desk serve` holds the desk's own state: per-session tiling policy
//! overrides and the command palette read from every configured product's
//! schema. It never drives venomx: the desk actions that change venomx
//! state (`tile split`, `workspace create`) are local commands that run in
//! the caller's process with the caller's own venomx identity (main.zig),
//! and `attach` is the interactive presentation client (attach.zig). doctor
//! reads venomx (read-only verbs, the daemon's own identity) only to report
//! key shadowing and unknown float presets.
const std = @import("std");
const cli = @import("cli");
const proto = @import("proto");
const cfg = @import("cfg");
const log = @import("log");
const supervisor = @import("supervisor");
const xdg = @import("xdg");
const desk = @import("venom-desk");
const tiling = desk.tiling;
const palette = desk.palette;
const keys = desk.keys;
const ck = @import("term_chrome").keys;

pub const tool = "venom-desk";

pub const TilingConfig = struct {
    /// Policy for sessions without a `tiling set` override.
    policy: tiling.Policy = .bsp,
};
pub const PaletteConfig = struct {
    /// Products whose verbs the palette lists (`<tool> mcp`, PATH lookup
    /// unless the entry has a slash).
    products: []const []const u8 = &palette.default_products,
};
pub const Config = struct {
    /// Policy for callers without a token; read-only by default.
    grants: proto.grants.Policy = .{},
    /// Log levels and formats; applied live on `config set` and reloads.
    log: log.Config = .{},
    tiling: TilingConfig = .{},
    palette: PaletteConfig = .{},
};
pub const ConfigStore = cfg.Store(Config, &.{});

pub fn validateConfig(value: Config) ?cfg.Validation {
    value.grants.check() catch return .{ .key = "grants" };
    if (value.palette.products.len > 32) return .{ .key = "palette.products" };
    for (value.palette.products) |p| if (p.len == 0 or p.len > 1024 or std.mem.indexOfScalar(u8, p, 0) != null) return .{ .key = "palette.products" };
    return null;
}

pub const input = @import("verbs.zon");
const manifest = .{ .format = input.format, .tool = input.tool, .summary = input.summary, .verbs = input.verbs ++ .{proto.events.manifest} };

/// Local commands (main.zig serves them).
pub const local = .{ .{
    .name = "attach",
    .summary = "Attach this terminal to a venomx session as its presentation client, in place of `venomx attach`. Keys: leader (venomx keys.leader) then ? lists them; : palette, i inbox, d detach.",
    .interactive = true,
    .params = .{
        .{ .name = "session", .summary = "venomx session ID", .type = .{ .kind = .string }, .required = true },
        .{ .name = "history", .summary = "Scrollback rows to backfill per pane", .type = .{ .kind = .integer, .min = 0, .max = 100000 }, .default = 2000 },
    },
    .result = .{ .kind = .object, .fields = .{} },
    .errors = .{
        .{ .code = "not_found.session", .summary = "No such session" },
        .{ .code = "denied.read", .summary = "The caller cannot read the session" },
    },
    .examples = .{.{ .params = .{ .session = "s0" }, .result = .{} }},
}, .{
    .name = "tile.split",
    .summary = "Open a new pane in a window where its tiling policy puts it (venomx pane.split with the caller's own venomx identity; the new pane carries the workspace tag). The policy is --policy, else the venom-desk daemon's for the session, else bsp. Never starts a daemon.",
    .params = .{
        .{ .name = "window", .summary = "venomx window ID", .type = .{ .kind = .string }, .required = true },
        .{ .name = "pane", .summary = "Pane the policy treats as focused (default: the window's last pane)", .type = .{ .kind = .string } },
        .{ .name = "policy", .summary = "Tiling policy", .type = .{ .kind = .string, .choices = .{ "manual", "bsp", "master-stack", "scrolling" } } },
        .{ .name = "argv", .summary = "Command of the new pane (JSON array, no shell); default $SHELL", .type = .{ .kind = .array, .items = .{ .kind = .string } } },
        .{ .name = "cols", .summary = "Window width the policy plans for", .type = .{ .kind = .integer, .min = 1, .max = 4096 }, .default = 80 },
        .{ .name = "rows", .summary = "Window height the policy plans for", .type = .{ .kind = .integer, .min = 1, .max = 4096 }, .default = 24 },
    },
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "pane", .summary = "The new pane", .type = .{ .kind = .string }, .required = true },
        .{ .name = "split", .summary = "The pane that was split", .type = .{ .kind = .string }, .required = true },
        .{ .name = "axis", .summary = "cols (side by side) or rows (stacked)", .type = .{ .kind = .string }, .required = true },
        .{ .name = "policy", .summary = "The policy applied", .type = .{ .kind = .string }, .required = true },
    } },
    .errors = .{
        .{ .code = "not_found.window", .summary = "No such window" },
        .{ .code = "conflict.empty_window", .summary = "The window has no tiled pane to split" },
        .{ .code = "failed.venomx", .summary = "venomx refused the split (data.code has its error)" },
    },
}, .{
    .name = "workspace.list",
    .summary = "List workspaces: venomx sessions (session list with the caller's venomx identity). Never starts a daemon.",
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "workspaces", .summary = "One per session", .type = .{ .kind = .array, .items = .{ .kind = .object, .fields = .{
            .{ .name = "session", .summary = "venomx session ID", .type = .{ .kind = .string }, .required = true },
            .{ .name = "name", .summary = "Workspace name (the session name)", .type = .{ .kind = .string }, .required = true },
        } } }, .required = true },
    } },
}, .{
    .name = "workspace.create",
    .summary = "Create a workspace: a venomx session with one window whose pane carries the workspace tag (caller's venomx identity). Never starts a daemon.",
    .params = .{
        .{ .name = "name", .summary = "Workspace (session) name", .type = .{ .kind = .string }, .required = true },
        .{ .name = "argv", .summary = "Command of the first pane (JSON array, no shell); default $SHELL", .type = .{ .kind = .array, .items = .{ .kind = .string } } },
    },
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "session", .summary = "The new session", .type = .{ .kind = .string }, .required = true },
        .{ .name = "name", .summary = "Workspace name", .type = .{ .kind = .string }, .required = true },
    } },
    .errors = .{
        .{ .code = "failed.venomx", .summary = "venomx refused (data.code has its error)" },
    },
} };

pub const key_help = "Leader (venomx keys.leader, default ctrl+a), then: d detach, tab next pane, shift+tab previous, n/p window, z zoom, ! next pane needing attention, f show/hide floats, F next float, L lock (until ctrl+alt+a), : palette, i inbox, ? keys, s split by tiling policy, % or \" split, b show/hide the rail. The leader twice sends it to the pane. Mouse: click focuses, wheel scrolls; a click on a status segment (on the line or in the rail) runs its click target.";

pub const App = cli.WithBootstrap(cfg.merge(cli.manifest.normalize(manifest)), cli.manifest.examples(manifest), .{ .local = local });

pub const skill_notes =
    \\venom-desk is a TUI workspace on venomx. `venom-desk attach --session <s>`
    \\is for humans only (it needs a terminal); agents never run it and never
    \\move a human's focus. The daemon (`venom-desk serve`) keeps per-session
    \\tiling policy overrides (`tiling list|set|clear`) and lists the command
    \\palette (`palette list --query <q>`): venom-desk's key actions plus every
    \\verb of the products in config palette.products. Desk actions that change
    \\venomx (`tile split --window <w>`, `workspace create --name <n>`,
    \\`workspace list`) run in your own process with your own venomx
    \\identity (VENOMX_TOKEN) and never start a daemon; they are not MCP tools.
    \\Describe your panes with venomx tags and status segments instead of
    \\drawing chrome. Use named flags and --json; every verb is read-only
    \\unless a grant allows more. Side effects: the socket, audit and daemon
    \\logs, ZON configuration (change it with `venom-desk config set`) and
    \\installed skills.
;

// ------------------------------------------------------------- tiling state

pub const max_overrides = 256;

/// Per-session tiling overrides, kept for the daemon's lifetime.
pub const Tiling = struct {
    gpa: std.mem.Allocator,
    config: *ConfigStore,
    events: *proto.events.Log,
    overrides: std.StringArrayHashMapUnmanaged(tiling.Policy) = .empty,

    pub fn deinit(self: *Tiling) void {
        for (self.overrides.keys()) |k| self.gpa.free(k);
        self.overrides.deinit(self.gpa);
    }
    fn sorted(self: *Tiling, a: std.mem.Allocator) ![]const Entry {
        const out = try a.alloc(Entry, self.overrides.count());
        for (self.overrides.keys(), self.overrides.values(), out) |k, v, *e| e.* = .{ .session = k, .policy = @tagName(v) };
        std.mem.sort(Entry, out, {}, struct {
            fn f(_: void, x: Entry, y: Entry) bool {
                return std.mem.lessThan(u8, x.session, y.session);
            }
        }.f);
        return out;
    }
    pub const Entry = struct { session: []const u8, policy: []const u8 };
    pub fn policyFor(self: *Tiling, session: []const u8) tiling.Policy {
        return self.overrides.get(session) orelse self.config.current().tiling.policy;
    }

    pub const List = struct {
        t: *Tiling,
        pub fn call(self: *List, c: *proto.Call) anyerror!void {
            try c.ok(.{ .default = @tagName(self.t.config.current().tiling.policy), .sessions = try self.t.sorted(c.arena()) });
        }
    };
    pub const Get = struct {
        t: *Tiling,
        pub const Params = struct { session: []const u8 };
        pub fn call(self: *Get, c: *proto.Call, p: Params) anyerror!void {
            const o = self.t.overrides.get(p.session);
            try c.ok(.{ .session = p.session, .policy = @tagName(o orelse self.t.config.current().tiling.policy), .override = o != null });
        }
    };
    pub const Set = struct {
        t: *Tiling,
        pub const Params = struct { session: []const u8, policy: []const u8 };
        pub fn call(self: *Set, c: *proto.Call, p: Params) anyerror!void {
            if (!validSession(p.session)) return c.fail("invalid_params.session", "session must be 1-64 printable ASCII characters", .{ .param = "session" });
            const policy = std.meta.stringToEnum(tiling.Policy, p.policy) orelse return c.fail("invalid_params.enum", "unknown policy", .{ .param = "policy" });
            const t = self.t;
            if (t.overrides.getPtr(p.session)) |v| {
                v.* = policy;
            } else {
                if (t.overrides.count() >= max_overrides) return c.fail("conflict.too_many", "too many tiling overrides; clear some first", .{ .max = max_overrides });
                const key = try t.gpa.dupe(u8, p.session);
                errdefer t.gpa.free(key);
                try t.overrides.put(t.gpa, key, policy);
            }
            try t.announce(p.session, @tagName(policy));
            try c.ok(.{ .session = p.session, .policy = @tagName(policy) });
        }
    };
    pub const Clear = struct {
        t: *Tiling,
        pub const Params = struct { session: []const u8 };
        pub fn call(self: *Clear, c: *proto.Call, p: Params) anyerror!void {
            const t = self.t;
            const removed = t.overrides.fetchOrderedRemove(p.session);
            if (removed) |kv| {
                t.gpa.free(kv.key);
                try t.announce(p.session, @tagName(t.config.current().tiling.policy));
            }
            try c.ok(.{ .session = p.session, .cleared = removed != null });
        }
    };
    fn announce(self: *Tiling, session: []const u8, policy: []const u8) !void {
        var buf: [96]u8 = undefined;
        const resource = std.fmt.bufPrint(&buf, "session:{s}", .{session}) catch return;
        self.events.append(resource, "tiling.changed", .{ .session = session, .policy = policy }) catch |err| if (err == error.OutOfMemory) return err;
    }
};

fn validSession(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |ch| if (ch < 0x21 or ch > 0x7e or ch == ':') return false;
    return true;
}

// ------------------------------------------------------------- palette

/// `palette.list` (read). Discovery runs the products once and again only
/// after `palette.products` changes.
pub const PaletteList = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: *ConfigStore,
    cache: ?palette.Palette = null,
    /// The products list the cache was built from, joined by NUL.
    built_for: std.ArrayList(u8) = .empty,

    pub const Params = struct { query: []const u8 = "" };
    pub fn deinit(self: *PaletteList) void {
        if (self.cache) |*p| p.deinit();
        self.built_for.deinit(self.gpa);
    }
    fn current(self: *PaletteList) !*palette.Palette {
        const products = self.config.current().palette.products;
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(self.gpa);
        for (products) |p| {
            try key.appendSlice(self.gpa, p);
            try key.append(self.gpa, 0);
        }
        if (self.cache != null and std.mem.eql(u8, key.items, self.built_for.items)) return &self.cache.?;
        if (self.cache) |*p| p.deinit();
        self.cache = palette.Palette.init(self.gpa);
        try self.cache.?.addLocals();
        try palette.discover(&self.cache.?, self.gpa, self.io, products);
        self.built_for.clearRetainingCapacity();
        try self.built_for.appendSlice(self.gpa, key.items);
        return &self.cache.?;
    }
    pub fn call(self: *PaletteList, c: *proto.Call, p: Params) anyerror!void {
        if (p.query.len > 256) return c.fail("invalid_params.query", "query is longer than 256 bytes", .{ .param = "query" });
        const a = c.arena();
        const pal = try self.current();
        const Out = struct { tool: []const u8, verb: []const u8, summary: []const u8, required: []const []const u8 };
        var entries: std.ArrayList(Out) = .empty;
        for (try pal.filter(a, p.query)) |m| {
            var req: std.ArrayList([]const u8) = .empty;
            for (m.entry.params) |param| if (param.required) try req.append(a, param.name);
            try entries.append(a, .{ .tool = m.entry.tool, .verb = m.entry.verb, .summary = m.entry.summary, .required = req.items });
        }
        try c.ok(.{ .reachable = pal.reachable.items, .entries = entries.items });
    }
};

// ------------------------------------------------------------- doctor

const ConfigCheck = struct {
    config: *ConfigStore,
    pub fn run(self: *ConfigCheck, r: *cli.doctor.Report) anyerror!void {
        const fix = try r.command("{s} config check --json", r.tool);
        self.config.check() catch |err| {
            if (err == error.OutOfMemory) return err;
            const code = if (err == error.InvalidConfig) self.config.failure.code else @errorName(err);
            return r.add("config.valid", .fail, try r.print("configuration is invalid: {s} (key '{s}')", .{ code, self.config.failure.key() }), fix);
        };
        try r.add("config.valid", .ok, "configuration is valid", fix);
    }
};

const EventsCheck = struct {
    events: *proto.events.Log,
    pub fn run(self: *EventsCheck, r: *cli.doctor.Report) anyerror!void {
        const st = self.events.status();
        try r.add("events.log", .ok, try r.print("event log {s} retains seq {d}..{d} ({d} of {d} bytes)", .{ st.source, st.low, st.high, st.bytes, st.limits.bytes }), try r.command("{s} events --follow=false --json", r.tool));
    }
};

/// Doctor items for a presentation client: the leader the
/// terminal must deliver, key shadowing, unknown float presets and nesting.
/// venomx is read with read-only verbs; when it does not answer the venomx
/// items are skipped (ok), so the desk daemon alone is healthy.
pub const DeskCheck = struct {
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    /// Socket of venomx to read; null is venomx's default.
    venomx_socket: ?[]const u8 = null,

    pub fn run(self: *DeskCheck, r: *cli.doctor.Report) anyerror!void {
        const venomx_fix = "venomx doctor --json";
        if (self.environ.getPosix("VENOMX_PANE")) |pane| {
            try r.add("desk.nesting", .warn, try r.print("this daemon runs inside venomx pane {s}; `venom-desk attach` there is a nested client (two status lines, the outer leader wins)", .{pane}), try r.command("{s} doctor --json", r.tool));
        } else try r.add("desk.nesting", .ok, "not inside a venomx pane", try r.command("{s} doctor --json", r.tool));

        var wire = desk.client.Wire.connect(self.gpa, .{ .socket = self.venomx_socket, .environ = self.environ, .connect_ms = 1000 }) catch |err| {
            const why = try r.print("venomx does not answer ({s}); key and float preset checks skipped", .{@errorName(err)});
            try r.add("keys.leader", .ok, why, venomx_fix);
            try r.add("keys.shadowed", .ok, why, venomx_fix);
            try r.add("floats.presets", .ok, why, venomx_fix);
            return;
        };
        defer wire.deinit();
        wire.timeout_ms = 2000;
        const c = wire.asClient();
        // The leader both presentation clients use and the key tables:
        // venomx `keys.list` (its `keys` config over the defaults file).
        const list: ?std.json.Value = switch (c.call(r.arena, "keys.list", .{}) catch Reply{ .err = "unavailable" }) {
            .ok => |v| v,
            .err => |code| blk: {
                try r.add("keys.leader", .ok, try r.print("venomx keys.list: {s}; skipped", .{code}), venomx_fix);
                break :blk null;
            },
        };
        if (list) |v| {
            var kc: keys.Config = .{};
            if (desk.json.str(v, "leader")) |t| kc.leader = t;
            if (desk.json.str(v, "unlock")) |t| kc.unlock = t;
            try leaderCheck(r, kc);
        }
        try self.shadowCheck(r, list);
        switch (c.call(r.arena, "doctor", .{}) catch Reply{ .err = "unavailable" }) {
            .ok => |v| {
                for (desk.json.array(v, "checks") orelse &.{}) |item| {
                    const id = desk.json.str(item, "id") orelse continue;
                    if (!std.mem.eql(u8, id, "floats.presets")) continue;
                    const st = std.meta.stringToEnum(cli.doctor.Status, desk.json.str(item, "status") orelse "ok") orelse .ok;
                    // A presentation-client problem, not a venomx failure.
                    return r.add("floats.presets", if (st == .fail) .warn else st, try r.print("venomx: {s}", .{desk.json.str(item, "message") orelse ""}), venomx_fix);
                }
                try r.add("floats.presets", .ok, "venomx reports no float preset check", venomx_fix);
            },
            .err => |code| try r.add("floats.presets", .ok, try r.print("venomx doctor: {s}; skipped", .{code}), venomx_fix),
        }
    }
    const Reply = desk.client.Reply;
    fn shadowCheck(self: *DeskCheck, r: *cli.doctor.Report, list: ?std.json.Value) !void {
        const fix = "venomx keys list --json";
        var map = try keys.Keymap.init(self.gpa, .{});
        defer map.deinit();
        const v = list orelse return r.add("keys.shadowed", .ok, "venomx keys.list unavailable; skipped", fix);
        map.loadList(v) catch return r.add("keys.shadowed", .ok, "venomx keys.list is unreadable; skipped", fix);
        const resolved = try keys.K.resolve(r.arena, map.tables, null);
        // Product tables that reuse a key of venom-desk's built-in table
        // after the leader take it away from the desk action.
        var text: std.ArrayList(u8) = .empty;
        var n: usize = 0;
        for (resolved.shadowed) |x| {
            if (n < 4) try text.print(r.arena, "{s}{s} \"{s}\" by {s}", .{ if (n > 0) "; " else "", x.table, x.key, x.by });
            n += 1;
        }
        if (n > 0) return r.add("keys.shadowed", .warn, try r.print("{d} binding(s) shadowed: {s}", .{ n, text.items }), fix);
        try r.add("keys.shadowed", .ok, "no venom-desk binding is shadowed", fix);
    }
};

pub fn leaderCheck(r: *cli.doctor.Report, kc: keys.Config) !void {
    const fix = "venomx config set --key keys.leader --value '\"ctrl+a\"'";
    const leader = ck.parseChord(kc.leader) orelse return r.add("keys.leader", .warn, try r.print("leader {s} is not a key venom-desk understands; it falls back to ctrl+a", .{kc.leader}), fix);
    const unlock = ck.parseChord(kc.unlock) orelse return r.add("keys.leader", .warn, try r.print("unlock key {s} is not a key venom-desk understands", .{kc.unlock}), fix);
    if (leader.plain()) return r.add("keys.leader", .warn, try r.print("leader {s} is an ordinary key: typing it in a pane opens the leader", .{kc.leader}), fix);
    if (!ck.legacyDeliverable(leader) or !ck.legacyDeliverable(unlock))
        return r.add("keys.leader", .warn, try r.print("leader {s} / unlock {s} needs the Kitty keyboard protocol; a terminal without it cannot send it", .{ kc.leader, kc.unlock }), fix);
    try r.add("keys.leader", .ok, try r.print("leader {s}, unlock {s}", .{ kc.leader, kc.unlock }), fix);
}

// ------------------------------------------------------------- serving

fn samePolicy(a: proto.grants.Policy, b: proto.grants.Policy) bool {
    if (a.max_token_ttl != b.max_token_ttl) return false;
    for ([_][]const proto.grants.Grant{ a.unknown, a.interactive }, [_][]const proto.grants.Grant{ b.unknown, b.interactive }) |left, right| {
        if (left.len != right.len) return false;
        for (left, right) |l, rr| if (l.right != rr.right or !std.mem.eql(u8, l.scope, rr.scope)) return false;
    }
    return true;
}

const ServeLoop = struct {
    io: std.Io,
    server: *proto.Server,
    events: *proto.events.Log,
    config: *ConfigStore,
    registry: *proto.grants.Registry,
    logger: *log.Logger,
    pub fn run(self: *ServeLoop, stop: *const supervisor.Stop) anyerror!void {
        while (!stop.requested()) {
            try self.server.poll(100);
            self.config.watch(proto.os.nowMs()) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.logger.warn("config watcher: reload failed", .{ .code = self.config.failure.code });
            };
            const current = self.config.current();
            if (!samePolicy(self.registry.policy, current.grants)) try self.registry.setPolicy(current.grants);
            self.logger.setConfig(current.log);
            try self.events.tick();
        }
    }
};

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    stopped: *const std.atomic.Value(bool),

    /// `venom-desk serve` (cli.Bootstrap).
    pub fn serve(self: *Daemon, path: proto.SocketOptions) anyerror!void {
        var logger = log.Logger.init(.{ .source = tool, .stderr = self.stderr, .file = self.openLog() });
        defer logger.deinit();
        var events = try proto.events.Log.init(self.gpa, tool, .{}, null);
        defer events.deinit();
        const config_path = try cfg.configPath(self.gpa, tool, self.environ);
        defer self.gpa.free(config_path);
        const defaults_paths = try cfg.defaultsPaths(self.gpa, tool, self.environ);
        defer cfg.freePaths(self.gpa, defaults_paths);
        var config = try ConfigStore.init(self.gpa, .{ .io = self.io, .path = config_path, .defaults = defaults_paths, .validate = validateConfig, .events = &events });
        defer config.deinit();
        events.snapshot = proto.events.Snapshot.init(&config);
        logger.setConfig(config.current().log);
        var registry = try proto.grants.Registry.init(self.gpa, tool, config.current().grants);
        defer registry.deinit();

        var t: Tiling = .{ .gpa = self.gpa, .config = &config, .events = &events };
        defer t.deinit();
        var list: Tiling.List = .{ .t = &t };
        var get: Tiling.Get = .{ .t = &t };
        var set: Tiling.Set = .{ .t = &t };
        var clear: Tiling.Clear = .{ .t = &t };
        var pal: PaletteList = .{ .gpa = self.gpa, .io = self.io, .config = &config };
        defer pal.deinit();

        var events_check: EventsCheck = .{ .events = &events };
        var config_check: ConfigCheck = .{ .config = &config };
        var server_check: cli.doctor.ServerCheck = .{ .server = undefined };
        var desk_check: DeskCheck = .{ .gpa = self.gpa, .environ = self.environ };
        const checks = [_]cli.doctor.Check{ .init("config", &config_check), .init("runtime", &server_check), .init("events", &events_check), .init("desk", &desk_check) };
        const digest = try App.digest(self.gpa);
        var standard: cli.Standard(App) = .init(.{ .notes = skill_notes, .home = self.environ.getPosix("HOME"), .checks = &checks, .schema = &digest });
        const handlers = [_]proto.Binding{
            .{ .verb = "tiling.list", .handler = proto.VerbHandler.init(&list) },
            .{ .verb = "tiling.get", .handler = proto.VerbHandler.typed(Tiling.Get.Params, &get) },
            .{ .verb = "tiling.set", .handler = proto.VerbHandler.typed(Tiling.Set.Params, &set) },
            .{ .verb = "tiling.clear", .handler = proto.VerbHandler.typed(Tiling.Clear.Params, &clear) },
            .{ .verb = "palette.list", .handler = proto.VerbHandler.typed(PaletteList.Params, &pal) },
            .{ .verb = "events", .handler = proto.VerbHandler.init(&events) },
        } ++ config.bindings() ++ standard.bindings();
        var dispatcher = try proto.Dispatcher.init(self.gpa, &App.schema, &handlers, .{}, null);
        defer dispatcher.deinit();
        var server = try proto.Server.init(self.gpa, .{
            .hello = .{ .identity = .{ .name = tool, .version = "0.0.0" }, .caps = &.{"cancel"}, .schema = &digest },
            .path = path,
            .registry = &registry,
        }, dispatcher.handler());
        defer server.deinit();
        server_check.server = &server;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const status_path = try xdg.siblingPath(arena_state.allocator(), server.path, "status.json");
        logger.info("listening", .{ .socket = server.path, .pid = std.c.getpid() });
        {
            var sup = supervisor.Supervisor.init(self.gpa, .{ .status_path = status_path, .logger = &logger });
            defer sup.deinit();
            var loop: ServeLoop = .{ .io = self.io, .server = &server, .events = &events, .config = &config, .registry = &registry, .logger = &logger };
            try sup.addThread("serve", supervisor.Task.init(&loop), .{});
            sup.run(self.stopped, .{});
        }
        dispatcher.cancelAll();
        server.shutdown();
        while (server.connections.items.len != 0) try server.poll(100);
        logger.info("stopped", .{});
    }

    fn openLog(self: *Daemon) ?std.c.fd_t {
        const file = xdg.path(self.gpa, .state, tool, tool ++ ".log", .{ .environ = self.environ, .uid = std.c.getuid() }) catch return null;
        defer self.gpa.free(file);
        return log.openFile(self.gpa, file) catch null;
    }
};

test "tiling session names" {
    try std.testing.expect(validSession("s0"));
    try std.testing.expect(!validSession(""));
    try std.testing.expect(!validSession("a b"));
    try std.testing.expect(!validSession("x:y"));
}
