//! Key tables, the leader and lock mode, as this
//! presentation client runs them. The client intercepts only the leader
//! (and, when locked, the unlock key); every other key goes to the focused
//! pane unchanged. Leader, lock and table mode are per-client state;
//! the tables themselves are shared (venomx `keys.list`, `keys.changed`)
//! plus venom-desk's built-ins.
//!
//! Chord syntax, precedence, the `keys.list` JSON form and the leader state
//! machine are venom-term's `chrome.keys`, the same implementation `venomx
//! attach` runs, and so are the leader popup's rows and timing
//! (`leader_popup`). This file adds venom-desk's commands and built-in
//! table.
const std = @import("std");
const json = @import("json.zig");
const ck = @import("term_chrome").keys;
const Tags = @import("term_chrome").tags.Tags;
const Value = std.json.Value;
const eq = std.mem.eql;

pub const Chord = ck.Chord;
pub const parseChord = ck.parseChord;
pub const fromKey = ck.fromKey;
pub const Mods = ck.Mods;
pub const chordText = ck.chordText;
pub const Layer = ck.Layer;
pub const Settings = ck.Settings;
pub const Placeholders = ck.Placeholders;
/// What the popup shows and when. `widgets.leader_popup` draws it.
pub const leader_popup = @import("term_chrome").leader_popup;
/// `{pane}`, `{window}`, `{session}`, `{popup_ticket}`.
pub const placeholders_text = ck.placeholders;

// ------------------------------------------------------------ targets

/// Typed local actions of this client. They never reach the
/// daemon, except attention clearing on focus.
pub const Local = enum {
    detach,
    @"focus-next",
    @"focus-prev",
    @"window-next",
    @"window-prev",
    zoom,
    @"focus-attention",
    @"toggle-floats",
    @"cycle-floats",
    lock,
    palette,
    inbox,
    /// The popup at the root, at once (`all-keys`).
    @"all-keys",
    /// Split by the active tiling policy.
    @"tile-split",
    /// `pane.split` of the focused pane (`%`, `"` as in venomx attach).
    @"split-right",
    @"split-down",
    @"dismiss-popup",
    /// Show or hide the rail (segments, groups and clicks).
    @"toggle-rail",

    fn parse(text: []const u8) ?Local {
        return std.meta.stringToEnum(Local, text);
    }
    fn name(l: Local) []const u8 {
        return @tagName(l);
    }
};

/// Tables over venom-desk's locals. venom-desk does not carry venomx's
/// verb schema, so any `.verb` name the daemon accepted is accepted here.
pub const K = ck.Tables(Local, .{ .parseLocal = Local.parse, .localName = Local.name });
pub const Target = K.Target;
pub const Binding = K.Binding;
pub const Table = K.Table;
pub const Router = K.Router;

// ------------------------------------------------------------ tables

/// venom-desk's built-in table: single keys after the leader. Matches
/// `venomx attach` where the action exists in both, so habits carry over, and
/// leaves the reserved sub-prefixes (`v`, `o`, `m`) to the tables.
pub const builtin_bindings = blk: {
    @setEvalBranchQuota(100_000);
    const locals = [_]struct { []const u8, Local }{
        .{ "d", .detach },
        .{ "tab", .@"focus-next" },
        .{ "shift+tab", .@"focus-prev" },
        .{ "n", .@"window-next" },
        .{ "p", .@"window-prev" },
        .{ "z", .zoom },
        .{ "!", .@"focus-attention" },
        .{ "f", .@"toggle-floats" },
        .{ "F", .@"cycle-floats" },
        .{ "L", .lock },
        .{ ":", .palette },
        .{ "i", .inbox },
        .{ "?", .@"all-keys" },
        .{ "s", .@"tile-split" },
        .{ "x", .@"dismiss-popup" },
        .{ "%", .@"split-right" },
        .{ "\"", .@"split-down" },
        .{ "b", .@"toggle-rail" },
    };
    var out: [locals.len]Binding = undefined;
    for (locals, &out) |l, *dst| dst.* = K.binding(l[0], .{ .local = l[1] });
    break :blk out;
};
pub const builtin_table: Table = .{ .name = "venom-desk", .layer = .builtin, .bindings = &builtin_bindings };

/// The `keys` scalars, with its defaults, until `keys.list` answers. They
/// are all set here, so nothing depends on venom-term's `Settings{}`.
pub const Config = struct {
    leader: []const u8 = "ctrl+a",
    unlock: []const u8 = "ctrl+alt+a",
    popup_delay_ms: u32 = 200,
    timeout_ms: u32 = 0,
    /// venomx's limit on both times.
    const max_ms = 60_000;
};

/// The key settings and tables this client resolves: its built-in table
/// plus the product tables from venomx `keys.list`.
pub const Keymap = struct {
    a: std.mem.Allocator,
    settings: Settings,
    /// Owns the tables from `keys.list`.
    arena: ?std.heap.ArenaAllocator = null,
    tables: []const Table = &.{builtin_table},

    pub fn init(a: std.mem.Allocator, config: Config) !Keymap {
        return .{ .a = a, .settings = .{
            .leader = parseChord(config.leader) orelse return error.InvalidKey,
            .unlock = parseChord(config.unlock) orelse return error.InvalidKey,
            .popup_delay_ms = config.popup_delay_ms,
            .timeout_ms = config.timeout_ms,
        } };
    }
    pub fn deinit(self: *Keymap) void {
        self.removeProduct();
    }
    /// Back to the built-in table only (settings stay). Leader state of a `Router` points
    /// into the tables: end it first.
    pub fn removeProduct(self: *Keymap) void {
        if (self.arena) |*x| x.deinit();
        self.arena = null;
        self.tables = &.{builtin_table};
    }

    /// Tables and settings from venomx `keys.list`, the same result
    /// `venomx attach` loads: the leader, unlock key, popup delay and timeout
    /// (venomx's `keys` config, defaults file under the user file), and the product,
    /// defaults-file and user tables, replacing those layers here. The
    /// built-in `venomx` table is venomx attach's own; venom-desk ships its
    /// built-ins instead. Tables that are not valid for this client
    /// (unknown local command, bad key) are skipped, as `venomx attach`
    /// does. An unreadable leader or unlock key keeps the current one.
    pub fn loadList(self: *Keymap, result: Value) !void {
        const items = json.array(result, "tables") orelse return error.BadKeys;
        var arena = std.heap.ArenaAllocator.init(self.a);
        errdefer arena.deinit();
        const x = arena.allocator();
        var tables: std.ArrayList(Table) = .empty;
        try tables.append(x, builtin_table);
        for (items) |item| if (try K.tableFromJson(x, item)) |t| {
            if (t.layer != .builtin) try tables.append(x, t);
        };
        var settings = self.settings;
        if (json.str(result, "leader")) |t| if (parseChord(t)) |c| {
            settings.leader = c;
        };
        if (json.str(result, "unlock")) |t| if (parseChord(t)) |c| {
            settings.unlock = c;
        };
        if (json.int(result, "popup_delay_ms")) |ms| if (ms >= 0) {
            settings.popup_delay_ms = @intCast(@min(ms, Config.max_ms));
        };
        // 0 means no timeout.
        if (json.int(result, "timeout_ms")) |ms| if (ms >= 0) {
            settings.timeout_ms = @intCast(@min(ms, Config.max_ms));
        };
        self.removeProduct();
        self.settings = settings;
        self.tables = tables.items;
        self.arena = arena;
    }
};

/// The environment of an `exec` child: the client's own, minus the venomx
/// token and principal and any credential-looking value,
/// so the child is authorized by whatever tool it calls
/// under that tool's own rules. One implementation with `venomx attach`:
/// venom-term's `chrome.exec_env`.
pub const execEnviron = @import("term_chrome").exec_env.childEnviron;

// ------------------------------------------------------------ tests

const testing = std.testing;

const keys_list =
    \\{"leader":"ctrl+b","unlock":"ctrl+alt+a","popup_delay_ms":50,"timeout_ms":1500,"tables":[{"name":"venomx","layer":"builtin","bindings":[{"key":"d","local":"detach"}]},
    \\ {"name":"venom","prefix":"a","layer":"product","source":"g9","when":[{"key":"owner","value":"venom"}],
    \\  "bindings":[{"key":"a","exec":["venom","approve","--pane","{pane}"]},
    \\          {"key":"s","verb":"pane.popup","args":"{\"preset\":\"venom.settings\",\"argv\":[\"venom\",\"settings\"],\"ticket\":\"{popup_ticket}\"}"}]},
    \\ {"name":"bad","prefix":"b","layer":"product","bindings":[{"key":"x","local":"scroll-page-up"}]},
    \\ {"name":"user","prefix":"u","layer":"user","bindings":[{"key":"t","exec":["htop"]}]},
    \\ {"name":"venom-os","prefix":"o","layer":"defaults","bindings":[{"key":"l","verb":"pane.popup","args":"{\"preset\":\"venom-os.launcher\",\"argv\":[\"launcher\"]}"}]}]}
;

test "keys.list: product, defaults and user tables and the leader load; venomx's built-ins and unknown locals are skipped" {
    const a = testing.allocator;
    var map = try Keymap.init(a, .{});
    defer map.deinit();
    var parsed = try std.json.parseFromSlice(Value, a, keys_list, .{});
    defer parsed.deinit();
    try map.loadList(parsed.value);
    try testing.expectEqual(@as(usize, 4), map.tables.len);
    try testing.expectEqualStrings("venom-desk", map.tables[0].name);
    try testing.expectEqualStrings("venom", map.tables[1].name);
    try testing.expectEqual(Layer.user, map.tables[2].layer);
    try testing.expectEqual(Layer.defaults, map.tables[3].layer);
    try testing.expect(map.settings.leader.eql(parseChord("ctrl+b").?));
    try testing.expectEqual(@as(u32, 50), map.settings.popup_delay_ms);
    try testing.expectEqual(@as(u32, 1500), map.settings.timeout_ms);
    try testing.expectEqualStrings("{popup_ticket}", (try std.json.parseFromSliceLeaky(Value, map.arena.?.allocator(), map.tables[1].bindings[1].target.verb.args, .{})).object.get("ticket").?.string);
    try testing.expectError(error.BadKeys, map.loadList(.{ .object = .empty }));
    map.removeProduct();
    try testing.expectEqual(@as(usize, 1), map.tables.len);
    try testing.expect(map.settings.leader.eql(parseChord("ctrl+b").?));
    try testing.expectError(error.InvalidKey, Keymap.init(a, .{ .leader = "hyper+x" }));
}

test "keys.list: timeout_ms 0 means no timeout, and absent settings stay" {
    const a = testing.allocator;
    var map = try Keymap.init(a, .{ .popup_delay_ms = 70, .timeout_ms = 900 });
    defer map.deinit();
    var parsed = try std.json.parseFromSlice(Value, a, "{\"timeout_ms\":0,\"tables\":[]}", .{});
    defer parsed.deinit();
    try map.loadList(parsed.value);
    try testing.expectEqual(@as(u32, 0), map.settings.timeout_ms);
    try testing.expectEqual(@as(u32, 70), map.settings.popup_delay_ms);
}

test "the keys defaults" {
    var map = try Keymap.init(testing.allocator, .{});
    defer map.deinit();
    const s = map.settings;
    try testing.expect(s.leader.eql(parseChord("ctrl+a").?));
    try testing.expect(s.unlock.eql(parseChord("ctrl+alt+a").?));
    try testing.expectEqual(@as(u32, 200), s.popup_delay_ms);
    try testing.expectEqual(@as(u32, 0), s.timeout_ms);
}

test "popup rows: tables after the leader, targets, and the leader itself" {
    const a = testing.allocator;
    var map = try Keymap.init(a, .{});
    defer map.deinit();
    var parsed = try std.json.parseFromSlice(Value, a, keys_list, .{});
    defer parsed.deinit();
    try map.loadList(parsed.value);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const s = arena.allocator();
    var agent: Tags = .{};
    defer agent.deinit(a);
    try agent.put(a, "owner", "venom");
    var r = Router.init(a);
    defer r.deinit();
    try testing.expect((try r.feed(map.settings, map.tables, .matching(&agent), parseChord("ctrl+b").?, 0)) == .leader);
    const lead = try leader_popup.rows(s, try r.next(s));
    var saw = [3]bool{ false, false, false };
    for (lead) |h| {
        saw[0] = saw[0] or (eq(u8, h.keys, "a") and eq(u8, h.label, "venom") and h.more);
        saw[1] = saw[1] or (eq(u8, h.keys, "d") and eq(u8, h.label, "detach"));
        saw[2] = saw[2] or (eq(u8, h.keys, "shift+tab") and eq(u8, h.label, "focus-prev"));
    }
    try testing.expect(saw[0] and saw[1] and saw[2]);
    try testing.expect((try r.feed(map.settings, map.tables, .matching(&agent), parseChord("a").?, 0)) == .partial);
    const sub = try leader_popup.rows(s, try r.next(s));
    try testing.expectEqual(@as(usize, 2), sub.len);
    try testing.expectEqualStrings("venom", sub[0].label);
    try testing.expectEqualStrings("pane.popup", sub[1].label);
}

test "exec children get no venomx token, principal or credential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fake = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";
    const env = try execEnviron(arena.allocator(), &.{
        "HOME=/h",
        "VENOMX_TOKEN=vnt1.secret",
        "VENOMX_PRINCIPAL=g1",
        "NOTE=see vnt1.venomx.g1." ++ fake,
        "OTHER_TOKEN=@owner",
        "VENOM_TOKEN=vnt1.venom.owner." ++ fake,
        "VENOMX_PANE=p1",
        "PATH=/bin",
    });
    try testing.expectEqual(@as(usize, 3), env.len);
    try testing.expectEqualStrings("HOME=/h", env[0]);
    try testing.expectEqualStrings("VENOMX_PANE=p1", env[1]);
    try testing.expectEqualStrings("PATH=/bin", env[2]);
}
