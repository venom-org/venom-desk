//! venom-desk as a presentation client of venomx: it
//! replaces `venomx attach`, renders the daemon's shared content (status
//! segments, attention, notifications, floats) and keeps all per-client
//! state to itself: window shown, focus, zoom, scroll, leader/lock
//! mode, float visibility and popups. No method here sends a verb that
//! changes another client's view; the only verbs are the user's own
//! mutations (`pane.split`, `window.create`, binding targets) and clearing
//! attention on the pane this user focused.
//!
//! This module is headless: `frame` draws a text grid, and keys arrive as
//! normalized names. The terminal loop (host TTY, pane streams,
//! pane content through venom-term) is a separate layer on top.
const std = @import("std");
const json = @import("json.zig");
const shared = @import("shared.zig");
const status = @import("status.zig");
const keys = @import("keys.zig");
const floats = @import("floats.zig");
const tiling = @import("tiling.zig");
const inbox = @import("inbox.zig");
const palette_mod = @import("palette.zig");
const Tags = @import("term_chrome").tags.Tags;
const Client = @import("client.zig").Client;
const Value = std.json.Value;
const eq = std.mem.eql;

/// Event types this client subscribes to (`events --types`), the same set
/// as `venomx attach` plus key tables.
pub const event_types = [_][]const u8{ "window.*", "pane.*", "session.*", "status.*", "notify.*", "config.*", "keys.*" };

pub const Overlay = enum { none, palette, inbox };

/// The palette's text input: a fuzzy query, the highlighted match,
/// then one prompt per `required` parameter of the chosen entry's schema.
pub const PaletteInput = struct {
    query: std.ArrayList(u8) = .empty,
    selected: usize = 0,
    /// Set while prompting for the chosen entry's required parameters.
    entry: ?*const palette_mod.Entry = null,
    /// Index into the entry's required parameters being prompted.
    param: usize = 0,
    /// Values typed so far, in required-parameter order.
    values: std.ArrayList([]u8) = .empty,
    /// The current prompt's text.
    field: std.ArrayList(u8) = .empty,

    fn reset(self: *PaletteInput, a: std.mem.Allocator) void {
        self.query.clearRetainingCapacity();
        self.selected = 0;
        self.entry = null;
        self.param = 0;
        for (self.values.items) |v| a.free(v);
        self.values.clearRetainingCapacity();
        self.field.clearRetainingCapacity();
    }
    fn deinit(self: *PaletteInput, a: std.mem.Allocator) void {
        self.reset(a);
        self.query.deinit(a);
        self.values.deinit(a);
        self.field.deinit(a);
    }
};

/// The per-client view state, for this client only.
pub const View = struct {
    window: ?[]u8 = null,
    focus: ?[]u8 = null,
    zoomed: bool = false,
    /// Rows scrolled back per pane; 0 is the live bottom.
    scroll: std.StringHashMapUnmanaged(u32) = .empty,
    floats_visible: bool = true,
    /// The focus to return to when the popup that took it closes.
    popup_back: ?[]u8 = null,
    /// Index into the visible floats when `leader F` cycles focus.
    float_focus: ?usize = null,
    overlay: Overlay = .none,
    /// The rail is shown (`toggle-rail`).
    rail: bool = false,
};

/// The rail's width in cells, its border column included, when the
/// terminal is wide enough (it takes at most a third of it).
pub const rail_width: u16 = 28;

pub const Options = struct {
    session: []const u8,
    cols: u16 = 80,
    rows: u16 = 24,
    policy: tiling.Policy = .bsp,
    /// argv for new panes (`split-right`, `split-down`, `tile-split`).
    shell: []const u8 = "/bin/sh",
    /// `VENOMX_PANE` was set: we are nested inside a venomx pane.
    nested: bool = false,
    keys: keys.Config = .{},
    /// Run an `exec` binding target: argv already substituted, env without
    /// a venomx token. Null runs it as a real child process.
    exec: ?*const fn (ctx: ?*anyopaque, argv: []const []const u8, env: []const []const u8) void = null,
    exec_ctx: ?*anyopaque = null,
    environ: []const []const u8 = &.{},
};

pub const Desk = struct {
    a: std.mem.Allocator,
    client: Client,
    options: Options,
    session: []u8,
    state: shared.State,
    view: View = .{},
    keymap: keys.Keymap,
    router: keys.Router,
    presets: floats.Presets,
    history: inbox.History,
    palette: palette_mod.Palette,
    config_arena: std.heap.ArenaAllocator,
    status_config: status.Config = .{},
    attention_config: status.AttentionConfig = .{},
    /// When the leader popup is up. `popupModel` is what it shows.
    popup: keys.leader_popup.Timer = .{},
    /// `keys.list` changed during leader mode: read it when leader mode ends.
    keys_stale: bool = false,
    /// False when venomx has no `keys.list` yet (an older venomx): only the
    /// built-in table is active.
    product_keys: bool = false,
    /// venomx's ID for this presentation client, learned from its first
    /// `popup.ticket`. Popups whose `client` is this ID are ours.
    client_id: ?[]u8 = null,
    message: std.ArrayList(u8) = .empty,
    /// Keys forwarded to the focused pane, for the terminal layer (and
    /// tests) to write to its pane stream.
    forwarded: std.ArrayList([]u8) = .empty,
    /// Palette query and parameter prompts while the palette is open.
    input: PaletteInput = .{},
    /// Counter for client-local notices in the inbox history.
    notices: u32 = 0,
    ended: bool = false,
    /// `ended` because this user detached (not because the session ended).
    detached: bool = false,
    now_ms: i64 = 0,
    clock: []const u8 = "",
    /// For `{clock}` in status templates; the terminal layer
    /// sets it with the local UTC offset.
    clock_now: ?status.template.Clock = null,
    /// `{host}` and `{user}` in status templates.
    host: []const u8 = "",
    user: []const u8 = "",
    /// Ids `toggle-segment` flipped on this client, until it detaches.
    toggled: std.ArrayList([]u8) = .empty,

    pub fn init(a: std.mem.Allocator, client: Client, options: Options) !Desk {
        var keymap = try keys.Keymap.init(a, options.keys);
        errdefer keymap.deinit();
        const session = try a.dupe(u8, options.session);
        errdefer a.free(session);
        var d: Desk = .{
            .a = a,
            .client = client,
            .options = options,
            .session = session,
            .state = shared.State.init(a),
            .keymap = keymap,
            .router = keys.Router.init(a),
            .presets = floats.Presets.init(a),
            .history = inbox.History.init(a),
            .palette = palette_mod.Palette.init(a),
            .config_arena = .init(a),
        };
        try d.palette.addLocals();
        return d;
    }
    pub fn deinit(self: *Desk) void {
        if (self.view.window) |w| self.a.free(w);
        if (self.view.focus) |f| self.a.free(f);
        if (self.view.popup_back) |b| self.a.free(b);
        if (self.client_id) |c| self.a.free(c);
        var it = self.view.scroll.keyIterator();
        while (it.next()) |k| self.a.free(k.*);
        self.view.scroll.deinit(self.a);
        for (self.forwarded.items) |k| self.a.free(k);
        self.forwarded.deinit(self.a);
        self.input.deinit(self.a);
        self.message.deinit(self.a);
        for (self.toggled.items) |t| self.a.free(t);
        self.toggled.deinit(self.a);
        self.palette.deinit();
        self.history.deinit();
        self.presets.deinit();
        self.router.deinit();
        self.keymap.deinit();
        self.state.deinit();
        self.config_arena.deinit();
        self.a.free(self.session);
    }

    fn say(self: *Desk, comptime fmt: []const u8, args: anytype) void {
        self.message.clearRetainingCapacity();
        self.message.print(self.a, fmt, args) catch {};
    }
    /// A client-local notification (e.g. a failed `exec` binding): shown on
    /// the message line and kept in this client's inbox history. It is not
    /// posted to the daemon, so other clients never see it.
    pub fn notice(self: *Desk, level: shared.NotifyLevel, comptime fmt: []const u8, args: anytype) !void {
        self.say(fmt, args);
        self.notices += 1;
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "local-{d}", .{self.notices}) catch unreachable;
        var note: shared.Note = .{ .id = @constCast(id), .text = self.message.items, .level = level, .pane = @constCast(""), .namespace = @constCast("venom-desk"), .expires = 0 };
        try self.history.record(&note, self.now_ms);
    }

    // -------------------------------------------------------- daemon state

    /// Fetch per-client settings the daemon holds: `status` and
    /// `attention` config, and product key tables. Called once after
    /// connecting and again on `config.*` / `keys.changed`.
    pub fn refresh(self: *Desk) !void {
        try self.reloadConfig();
        try self.reloadKeys();
    }
    fn reloadConfig(self: *Desk) !void {
        _ = self.config_arena.reset(.retain_capacity);
        self.status_config = .{};
        self.attention_config = .{};
        const a = self.config_arena.allocator();
        switch (try self.client.call(a, "config.get", .{ .key = "status" })) {
            .ok => |v| if (json.str(v, "content")) |c| {
                self.status_config = status.parseConfig(status.Config, a, c) catch .{};
            },
            .err => {},
        }
        switch (try self.client.call(a, "config.get", .{ .key = "attention" })) {
            .ok => |v| if (json.str(v, "content")) |c| {
                self.attention_config = status.parseConfig(status.AttentionConfig, a, c) catch .{};
            },
            .err => {},
        }
        // The leader, unlock key, timeout and key tables come from
        // `keys.list` (reloadKeys): venomx merges its defaults file and the
        // user's `keys` config there, so both presentation clients of a
        // session share one leader. Float presets are resolved by venomx
        // too: each float's published spec is already default + registered
        // preset + config preset + explicit fields, and a preset
        // change re-publishes it with `pane.placed`.
    }
    fn reloadKeys(self: *Desk) !void {
        // Leader state points into the tables, so they change only outside it,
        // as in `venomx attach`: the next key must not fall through to a pane.
        if (self.router.pending()) {
            self.keys_stale = true;
            return;
        }
        self.keys_stale = false;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        switch (try self.client.call(arena.allocator(), "keys.list", .{})) {
            .ok => |v| {
                self.keymap.loadList(v) catch |err| {
                    self.keymap.removeProduct();
                    self.say("keys.list: {s}", .{@errorName(err)});
                    return;
                };
                self.product_keys = true;
                if (json.str(v, "leader")) |t| if (keys.parseChord(t) == null) self.say("keys.leader {s} is not a valid key; keeping the current leader", .{t});
            },
            .err => {
                self.keymap.removeProduct();
                self.product_keys = false;
            },
        }
    }

    /// One event item from the `events` subscription.
    pub fn handle(self: *Desk, item: Value) !void {
        const kind = json.str(item, "type") orelse "";
        const change = try self.state.apply(item, self.now_ms);
        if (eq(u8, kind, "pane.created")) if (json.get(item, "data")) |data| if (json.str(data, "pane")) |id| try self.popupOpened(id);
        switch (change) {
            .none, .chrome => {},
            .topology => if (!self.state.in_snapshot) try self.settle(),
            .posted => |i| try self.history.record(&self.state.notes.items[i], self.now_ms),
            .session_removed => |id| if (eq(u8, id, self.session)) {
                self.ended = true;
            },
            .keys => try self.reloadKeys(),
            // `keys.*` config (leader, user tables) arrives through
            // `keys.list` too, so a config change reloads both.
            .config => try self.refresh(),
        }
    }
    /// A popup opened for this client takes its focus; the focus it
    /// had comes back when the popup closes. A floating pane never takes
    /// focus by being created.
    fn popupOpened(self: *Desk, id: []const u8) !void {
        const p = self.state.pane(id) orelse return;
        if (!self.mine(p)) return;
        if (self.view.focus) |f| {
            self.setOwned(&self.view.popup_back, try self.a.dupe(u8, f));
        }
        try self.focus(id);
    }
    /// A popup opened for this client (the others' are never shown here).
    pub fn mine(self: *const Desk, p: *const shared.Pane) bool {
        const id = self.client_id orelse return false;
        return p.layer == .popup and eq(u8, p.client, id);
    }
    pub fn handleLine(self: *Desk, line: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, line, .{});
        defer parsed.deinit();
        try self.handle(parsed.value);
    }

    /// Keep the view pointing at things that exist: the shown window falls
    /// back to the session's lowest window ID, focus to its first pane.
    fn settle(self: *Desk) !void {
        if (self.view.window) |w| if (self.window(w) == null) self.setOwned(&self.view.window, null);
        if (self.view.window == null) {
            var best: ?[]const u8 = null;
            for (self.state.windows.items) |w| if (eq(u8, w.session, self.session)) {
                if (best == null or idLess(w.id, best.?)) best = w.id;
            };
            if (best) |b| try self.setWindow(b);
        }
        const moved = if (self.view.focus) |f| !self.visible(f) else true;
        if (self.view.focus) |f| if (!self.visible(f)) self.setOwned(&self.view.focus, null);
        // Back to where the human was before a popup took the focus.
        if (self.view.focus == null) if (self.view.popup_back) |b| {
            self.view.popup_back = null;
            if (self.visible(b)) self.view.focus = b else self.a.free(b);
        };
        if (self.view.focus == null) if (self.currentWindow()) |w| {
            for (w.nodes) |n| if (n.pane) |p| {
                self.setOwned(&self.view.focus, try self.a.dupe(u8, p));
                break;
            };
        };
        if (moved) try self.refocusLeader();
    }
    fn setOwned(self: *Desk, slot: *?[]u8, value: ?[]u8) void {
        if (slot.*) |old| self.a.free(old);
        slot.* = value;
    }
    fn setWindow(self: *Desk, id: []const u8) !void {
        self.setOwned(&self.view.window, try self.a.dupe(u8, id));
        self.view.zoomed = false;
        self.view.float_focus = null;
    }
    fn window(self: *const Desk, id: []const u8) ?*shared.Window {
        const w = self.state.window(id) orelse return null;
        return if (eq(u8, w.session, self.session)) w else null;
    }
    pub fn currentWindow(self: *const Desk) ?*shared.Window {
        return self.window(self.view.window orelse return null);
    }
    /// Window IDs of this session, ordered by ID.
    pub fn windowIds(self: *const Desk, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.state.windows.items) |w| if (eq(u8, w.session, self.session)) try out.append(a, w.id);
        std.mem.sort([]const u8, out.items, {}, struct {
            fn f(_: void, x: []const u8, y: []const u8) bool {
                return idLess(x, y);
            }
        }.f);
        return out.toOwnedSlice(a);
    }
    /// Floats of the shown window, lowest z first (drawn in that order),
    /// then this client's popups, which show whatever the window.
    pub fn windowFloats(self: *const Desk, a: std.mem.Allocator) ![]*shared.Pane {
        var out: std.ArrayList(*shared.Pane) = .empty;
        const w = self.view.window orelse "";
        for (self.state.panes.items) |*p| {
            if (p.layer == .float and eq(u8, p.window, w) and eq(u8, p.session, self.session)) try out.append(a, p);
            if (self.mine(p)) try out.append(a, p);
        }
        std.mem.sort(*shared.Pane, out.items, {}, struct {
            fn f(_: void, x: *shared.Pane, y: *shared.Pane) bool {
                if (x.layer != y.layer) return x.layer == .float;
                if (x.z != y.z) return x.z < y.z;
                return idLess(x.id, y.id);
            }
        }.f);
        return out.toOwnedSlice(a);
    }
    /// A pane this client can focus: a tile of the shown window, or one of
    /// its floats while the float layer is visible.
    fn visible(self: *const Desk, pane: []const u8) bool {
        if (self.state.pane(pane)) |p| if (self.mine(p)) return true;
        const w = self.currentWindow() orelse return false;
        if (w.contains(pane)) return true;
        const p = self.state.pane(pane) orelse return false;
        return self.view.floats_visible and p.layer == .float and eq(u8, p.window, w.id);
    }
    fn focusedTags(self: *const Desk) *const Tags {
        const empty = struct {
            const t: Tags = .{};
        };
        const f = self.view.focus orelse return &empty.t;
        const p = self.state.pane(f) orelse return &empty.t;
        return &p.tags;
    }

    // -------------------------------------------------------- focus

    /// Focusing a pane clears its attention, under this client's own
    /// identity, unless `attention.sticky`. Nothing else is sent: focus is
    /// never broadcast.
    pub fn focus(self: *Desk, pane: []const u8) !void {
        if (self.view.focus) |f| if (eq(u8, f, pane)) return self.clearAttention(pane);
        self.setOwned(&self.view.focus, try self.a.dupe(u8, pane));
        try self.refocusLeader();
        try self.clearAttention(pane);
    }
    /// Focus moved, so leader mode goes on with the new pane's tables, or
    /// ends if the typed keys no longer lead anywhere. An open popup follows,
    /// since its rows come from the router; one a sticky group hid stays hidden.
    fn refocusLeader(self: *Desk) !void {
        if (!self.router.pending()) return;
        _ = try self.router.refocus(self.keymap.tables, .matching(self.focusedTags()));
        _ = self.syncPopup();
    }
    fn clearAttention(self: *Desk, pane: []const u8) !void {
        const p = self.state.pane(pane) orelse return;
        if (p.level == .none or self.attention_config.sticky) return;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        switch (try self.client.call(arena.allocator(), "pane.attention", .{ .pane = pane, .clear = true })) {
            .ok => {},
            .err => |code| self.say("attention: {s}", .{code}),
        }
    }
    fn cycleFocus(self: *Desk, step: isize) !void {
        const w = self.currentWindow() orelse return;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.a);
        for (w.nodes) |n| if (n.pane) |p| try ids.append(self.a, p);
        if (ids.items.len == 0) return;
        var at: usize = 0;
        if (self.view.focus) |f| for (ids.items, 0..) |id, i| if (eq(u8, id, f)) {
            at = i;
        };
        const n: isize = @intCast(ids.items.len);
        const next: usize = @intCast(@mod(@as(isize, @intCast(at)) + step, n));
        self.view.zoomed = false;
        try self.focus(ids.items[next]);
    }
    fn cycleWindow(self: *Desk, step: isize) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const ids = try self.windowIds(arena.allocator());
        if (ids.len == 0) return;
        var at: usize = 0;
        if (self.view.window) |cur| for (ids, 0..) |id, i| if (eq(u8, id, cur)) {
            at = i;
        };
        const n: isize = @intCast(ids.len);
        const next: usize = @intCast(@mod(@as(isize, @intCast(at)) + step, n));
        try self.setWindow(ids[next]);
        self.setOwned(&self.view.focus, null);
        try self.settle();
    }
    /// `focus-attention`: the next pane of this session needing
    /// attention, most urgent first, switching this client's window if
    /// needed. Only this client's view moves.
    pub fn focusAttention(self: *Desk) !void {
        var best: ?*shared.Pane = null;
        for (self.state.panes.items) |*p| if (p.level != .none and eq(u8, p.session, self.session)) {
            if (p.layer == .popup and !self.mine(p)) continue;
            if (self.view.focus) |f| if (eq(u8, f, p.id)) continue;
            if (best == null or @backingInt(p.level) > @backingInt(best.?.level)) best = p;
        };
        const target = best orelse return self.say("no pane needs attention", .{});
        const id = try self.a.dupe(u8, target.id);
        defer self.a.free(id);
        if (self.state.windowOf(id)) |w| if (self.view.window == null or !eq(u8, w.id, self.view.window.?)) try self.setWindow(w.id);
        if (target.layer != .tile) self.view.floats_visible = true;
        try self.focus(id);
    }
    pub fn scrollBy(self: *Desk, pane: []const u8, rows: i32) !void {
        const gop = try self.view.scroll.getOrPut(self.a, pane);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.a.dupe(u8, pane) catch |err| {
                _ = self.view.scroll.remove(pane);
                return err;
            };
            gop.value_ptr.* = 0;
        }
        const next = @as(i64, gop.value_ptr.*) + rows;
        gop.value_ptr.* = @intCast(@max(0, next));
    }

    // -------------------------------------------------------- keys

    /// One key from the host terminal, by its Kitty-protocol name
    /// (`ctrl+space`, `a`, `shift+tab`). Text that is not one key passes.
    pub fn press(self: *Desk, key: []const u8) !void {
        // The open palette takes every key until it closes.
        if (self.view.overlay == .palette and !self.router.pending()) return self.paletteKey(key);
        if (self.view.overlay != .none and !self.router.pending() and eq(u8, key, "escape")) {
            self.view.overlay = .none;
            return;
        }
        const chord = keys.parseChord(key) orelse return self.forward(key);
        const outcome = try self.router.feed(self.keymap.settings, self.keymap.tables, .matching(self.focusedTags()), chord, self.now_ms);
        switch (outcome) {
            .pass => try self.forward(key),
            .send_leader => {
                const text = try keys.chordText(self.a, self.keymap.settings.leader);
                defer self.a.free(text);
                try self.forward(text);
            },
            // The leader closes an open inbox: its keys go to the router now.
            .leader => self.view.overlay = .none,
            .run => |b| try self.run(&b.target),
            .partial, .unlocked, .unbound, .overflow => {},
        }
        _ = try self.routerMoved();
    }
    /// Once per loop turn, before drawing: the leader timeout and the popup's
    /// delay. True when the frame is out of date.
    pub fn tick(self: *Desk, now: i64) !bool {
        self.now_ms = now;
        const timed_out = self.router.tick(now);
        const popup_moved = try self.routerMoved();
        return timed_out or popup_moved;
    }
    /// After anything that can change the router. True when the popup's part of
    /// the frame is out of date.
    fn routerMoved(self: *Desk) !bool {
        if (self.keys_stale and !self.router.pending()) try self.reloadKeys();
        return self.syncPopup();
    }
    fn syncPopup(self: *Desk) bool {
        return self.popup.sync(.of(&self.router), self.keymap.settings.popup_delay_ms, self.now_ms);
    }
    /// When `tick` must run next for the popup or `keys.timeout_ms`; null when
    /// nothing is waiting, so an open popup costs no wakeups.
    pub fn nextWake(self: *const Desk) ?i64 {
        const popup = self.popup.nextWake();
        const deadline = self.router.nextDeadline();
        if (popup != null and deadline != null) return @min(popup.?, deadline.?);
        return popup orelse deadline;
    }
    /// This frame's popup, for `widgets.leader_popup`. Allocates in `a`
    /// (an arena).
    pub fn popupModel(self: *const Desk, a: std.mem.Allocator) !keys.leader_popup.Model {
        return keys.leader_popup.model(a, "venom-desk", &self.router, .{ .key = self.keymap.settings.leader, .label = "send-leader" });
    }
    /// A paste goes to the pane, and the next typed key must too.
    pub fn endLeader(self: *Desk) void {
        self.router.end();
        _ = self.syncPopup();
    }
    fn forward(self: *Desk, key: []const u8) !void {
        const k = try self.a.dupe(u8, key);
        errdefer self.a.free(k);
        try self.forwarded.append(self.a, k);
    }
    fn placeholders(self: *const Desk) keys.Placeholders {
        return .{ .pane = self.view.focus orelse "", .window = self.view.window orelse "", .session = self.session };
    }
    /// Mint a single-use popup ticket bound to this client and
    /// session (10 s), for one binding's `{popup_ticket}`. Null (with the
    /// reason on the message line) when venomx refuses.
    pub fn mintTicket(self: *Desk, a: std.mem.Allocator) !?[]const u8 {
        const reply = try self.client.call(a, "popup.ticket", .{ .session = self.session, .window = self.view.window });
        const v = switch (reply) {
            .ok => |v| v,
            .err => |code| {
                self.say("popup.ticket: {s}", .{code});
                return null;
            },
        };
        const ticket = json.str(v, "ticket") orelse {
            self.say("popup.ticket: no ticket in the reply", .{});
            return null;
        };
        if (json.str(v, "client")) |id| if (self.client_id == null or !eq(u8, self.client_id.?, id)) {
            self.setOwned(&self.client_id, try self.a.dupe(u8, id));
        };
        return ticket;
    }
    fn usesTicket(target: *const keys.Target) bool {
        const t = keys.placeholders_text[3];
        return switch (target.*) {
            .local => false,
            // A client's own pane.popup binding mints its ticket implicitly.
            .verb => |v| eq(u8, v.name, "pane.popup") or std.mem.indexOf(u8, v.args, "\"" ++ t ++ "\"") != null,
            .exec => |argv| for (argv) |x| {
                if (eq(u8, x, t)) break true;
            } else false,
        };
    }
    fn run(self: *Desk, target: *const keys.Target) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        var ph = self.placeholders();
        if (usesTicket(target)) ph.popup_ticket = try self.mintTicket(a) orelse return;
        switch (target.*) {
            .local => |l| try self.local(l),
            .verb => |v| {
                var args = try ph.args(a, v.args);
                if (eq(u8, v.name, "pane.popup") and args == .object) try args.object.put(a, "ticket", .{ .string = ph.popup_ticket });
                switch (try self.client.call(a, v.name, args)) {
                    .ok => {},
                    .err => |code| self.failed(v.name, code),
                }
            },
            .exec => |argv_in| {
                const argv = try ph.argv(a, argv_in);
                const env = try keys.execEnviron(a, self.options.environ);
                if (self.options.exec) |f| f(self.options.exec_ctx, argv, env) else spawnDetached(a, argv, env) catch |err| try self.notice(.warn, "exec {s}: {s}", .{ argv[0], @errorName(err) });
            },
        }
    }
    /// A binding's verb failed: the code, worded for the popup errors.
    fn failed(self: *Desk, verb: []const u8, code: []const u8) void {
        if (eq(u8, code, "denied.popup_ticket")) return self.say("{s}: popup ticket refused (spent, expired or another client's)", .{verb});
        if (eq(u8, code, "not_found.client")) return self.say("{s}: the popup's client has detached", .{verb});
        self.say("{s}: {s}", .{ verb, code });
    }
    /// `dismiss-popup`: close the focused popup of this client, else its
    /// topmost one (venomx removes it; every client sees `pane.removed`).
    /// With none open it closes the overlay.
    fn dismissPopup(self: *Desk) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        var target: ?[]const u8 = null;
        if (self.view.focus) |f| if (self.state.pane(f)) |p| if (self.mine(p)) {
            target = p.id;
        };
        if (target == null) {
            const fl = try self.windowFloats(a);
            var i = fl.len;
            while (i > 0) {
                i -= 1;
                if (fl[i].layer == .popup) {
                    target = fl[i].id;
                    break;
                }
            }
        }
        const pane = target orelse {
            self.view.overlay = .none;
            return;
        };
        switch (try self.client.call(a, "pane.kill", .{ .pane = pane, .remove = true })) {
            .ok => {},
            .err => |code| self.failed("pane.kill", code),
        }
    }
    pub fn local(self: *Desk, l: keys.Local) !void {
        switch (l) {
            .detach => {
                self.detached = true;
                self.ended = true;
            },
            .@"focus-next" => try self.cycleFocus(1),
            .@"focus-prev" => try self.cycleFocus(-1),
            .@"window-next" => try self.cycleWindow(1),
            .@"window-prev" => try self.cycleWindow(-1),
            // Zoom is this client's viewing choice; nothing is sent.
            .zoom => self.view.zoomed = !self.view.zoomed and self.view.focus != null,
            .@"focus-attention" => try self.focusAttention(),
            .@"toggle-floats" => {
                self.view.floats_visible = !self.view.floats_visible;
                if (!self.view.floats_visible) {
                    self.view.float_focus = null;
                    if (self.view.focus) |f| if (!self.visible(f)) {
                        self.setOwned(&self.view.focus, null);
                        try self.settle();
                    };
                }
            },
            .@"cycle-floats" => {
                var arena = std.heap.ArenaAllocator.init(self.a);
                defer arena.deinit();
                const fl = try self.windowFloats(arena.allocator());
                if (fl.len == 0) return self.say("no floats", .{});
                self.view.floats_visible = true;
                const next = if (self.view.float_focus) |i| (i + 1) % fl.len else fl.len - 1;
                self.view.float_focus = next;
                try self.focus(fl[next].id);
            },
            .lock => {
                self.router.lock();
                self.view.overlay = .none;
            },
            .palette => {
                self.input.reset(self.a);
                self.view.overlay = if (self.view.overlay == .palette) .none else .palette;
            },
            .inbox => {
                self.view.overlay = if (self.view.overlay == .inbox) .none else .inbox;
                if (self.view.overlay == .inbox) self.history.markAllRead();
            },
            .@"all-keys" => {
                const timeout = self.keymap.settings.timeout_ms;
                try self.router.begin(self.keymap.tables, .matching(self.focusedTags()), if (timeout == 0) keys.Router.no_deadline else self.now_ms + timeout);
                self.popup = .{ .shown = true, .last = .of(&self.router) };
            },
            .@"dismiss-popup" => if (self.view.overlay != .none) {
                self.view.overlay = .none;
            } else try self.dismissPopup(),
            .@"split-right" => try self.split(.cols),
            .@"split-down" => try self.split(.rows),
            .@"tile-split" => try self.tileSplit(),
            .@"toggle-rail" => {
                self.view.rail = !self.view.rail;
                if (self.view.rail and self.railRect() == null) self.say("too narrow for the rail", .{});
            },
        }
    }
    /// `toggle-segment <id>`: hide or show a segment on this
    /// client only, until it detaches.
    pub fn toggleSegment(self: *Desk, id: []const u8) !void {
        for (self.toggled.items, 0..) |t, i| if (eq(u8, t, id)) {
            self.a.free(self.toggled.orderedRemove(i));
            return;
        };
        try self.toggled.ensureUnusedCapacity(self.a, 1);
        self.toggled.appendAssumeCapacity(try self.a.dupe(u8, id));
    }

    // -------------------------------------------------------- palette input

    /// Palette matches for the current query (in `a`).
    pub fn paletteMatches(self: *Desk, a: std.mem.Allocator) ![]palette_mod.Palette.Match {
        return self.palette.filter(a, self.input.query.items);
    }
    fn requiredParams(entry: *const palette_mod.Entry, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (entry.params) |p| if (p.required) try out.append(a, p.name);
        return out.toOwnedSlice(a);
    }
    /// One key while the palette is open: text edits the query (or the
    /// current parameter prompt), up/down move the highlight, enter picks
    /// or confirms, escape closes.
    pub fn paletteKey(self: *Desk, key: []const u8) !void {
        const in = &self.input;
        const editing = if (in.entry != null) &in.field else &in.query;
        if (eq(u8, key, "escape")) {
            in.reset(self.a);
            self.view.overlay = .none;
            return;
        }
        if (eq(u8, key, "backspace")) {
            // Drop one UTF-8 code point.
            var n = editing.items.len;
            while (n > 0) {
                n -= 1;
                if (editing.items[n] & 0xc0 != 0x80) break;
            }
            editing.shrinkRetainingCapacity(n);
            in.selected = 0;
            return;
        }
        if (in.entry == null and (eq(u8, key, "up") or eq(u8, key, "shift+tab"))) {
            in.selected -|= 1;
            return;
        }
        if (in.entry == null and (eq(u8, key, "down") or eq(u8, key, "tab"))) {
            in.selected += 1;
            return;
        }
        if (eq(u8, key, "enter")) return self.paletteEnter();
        const text: []const u8 = if (eq(u8, key, "space")) " " else if (key.len > 0 and std.mem.indexOfScalar(u8, key, '+') == null and (std.unicode.utf8CountCodepoints(key) catch 0) == 1) key else if (eq(u8, key, "+")) "+" else return;
        if (editing.items.len + text.len > 256) return;
        try editing.appendSlice(self.a, text);
        if (in.entry == null) in.selected = 0;
    }
    fn paletteEnter(self: *Desk) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        const in = &self.input;
        if (in.entry == null) {
            const ms = try self.paletteMatches(a);
            if (ms.len == 0) return;
            in.entry = ms[@min(in.selected, ms.len - 1)].entry;
            in.param = 0;
        } else {
            try in.values.append(self.a, try in.field.toOwnedSlice(self.a));
            in.param += 1;
        }
        const entry = in.entry.?;
        const req = try requiredParams(entry, a);
        if (in.param < req.len) return; // prompt for the next one
        // Every required parameter is in: run it with the client's identity.
        var obj: std.json.ObjectMap = .empty;
        for (req, in.values.items) |name, value| {
            // A value that parses as JSON (numbers, arrays, booleans) is
            // passed as such; anything else is a string.
            const v = std.json.parseFromSliceLeaky(Value, a, value, .{}) catch Value{ .string = value };
            try obj.put(a, name, if (v == .object or v == .null) Value{ .string = value } else v);
        }
        const params = try std.json.Stringify.valueAlloc(a, Value{ .object = obj }, .{});
        in.reset(self.a);
        self.view.overlay = .none;
        try self.runEntry(entry, params);
    }
    /// The palette popup's lines: the query (or prompt) line, then matches.
    pub fn paletteView(self: *Desk, a: std.mem.Allocator) !struct { title: []const u8, lines: []const []const u8, selected: ?usize } {
        const in = &self.input;
        if (in.entry) |entry| {
            const req = try requiredParams(entry, a);
            const name = if (in.param < req.len) req[in.param] else "";
            const lines = try a.alloc([]const u8, 2);
            lines[0] = try std.fmt.allocPrint(a, "{s}", .{try entry.command(a)});
            lines[1] = try std.fmt.allocPrint(a, "{s}: {s}_", .{ name, in.field.items });
            return .{ .title = "palette", .lines = lines, .selected = null };
        }
        var lines: std.ArrayList([]const u8) = .empty;
        try lines.append(a, try std.fmt.allocPrint(a, "> {s}_", .{in.query.items}));
        const ms = try self.paletteMatches(a);
        if (ms.len > 0 and in.selected >= ms.len) in.selected = ms.len - 1;
        for (ms) |m| try lines.append(a, try std.fmt.allocPrint(a, "{s}  {s}", .{ try m.entry.command(a), m.entry.summary }));
        return .{ .title = "palette", .lines = lines.items, .selected = if (ms.len > 0) in.selected + 1 else null };
    }

    // -------------------------------------------------------- mutations

    fn workspaceTags(self: *const Desk) [1]TagPair {
        return workspaceTagsFor(self.workspaceName());
    }
    /// The workspace is this session; its name is the session's tag value.
    pub fn workspaceName(self: *const Desk) []const u8 {
        for (self.state.panes.items) |p| if (eq(u8, p.session, self.session)) if (p.tags.get(workspace_tag)) |w| return w;
        return self.session;
    }
    fn split(self: *Desk, axis: tiling.Axis) !void {
        const pane = self.view.focus orelse return self.say("no pane", .{});
        try self.splitPane(pane, axis);
    }
    fn splitPane(self: *Desk, pane: []const u8, axis: tiling.Axis) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const area = self.windowArea();
        const r = try self.client.call(arena.allocator(), "pane.split", .{
            .pane = pane,
            .axis = @tagName(axis),
            .argv = &[_][]const u8{self.options.shell},
            .cols = area.width,
            .rows = area.height,
            .tags = self.workspaceTags(),
        });
        switch (r) {
            .ok => {},
            .err => |code| self.say("pane.split: {s}", .{code}),
        }
    }
    /// The tiling policy decides where; `pane.split` does it.
    pub fn tileSplit(self: *Desk) !void {
        const w = self.currentWindow() orelse return self.say("no window", .{});
        const plan = try tiling.plan(self.a, self.options.policy, w.nodes, self.view.focus, self.windowArea()) orelse return;
        try self.splitPane(plan.pane, plan.axis);
    }
    /// `pane.place`: move a float into the tiling at the policy's
    /// spot, or a tile into the float layer with a preset.
    pub fn placeTiled(self: *Desk, pane: []const u8) !void {
        const w = self.currentWindow() orelse return self.say("no window", .{});
        const plan = try tiling.plan(self.a, self.options.policy, w.nodes, self.view.focus, self.windowArea()) orelse return self.say("no tile to place next to", .{});
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        switch (try self.client.call(arena.allocator(), "pane.place", .{ .pane = pane, .tile = .{ .target = plan.pane, .axis = @tagName(plan.axis) } })) {
            .ok => {},
            .err => |code| self.say("pane.place: {s}", .{code}),
        }
    }
    pub fn placeFloat(self: *Desk, pane: []const u8, preset: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        switch (try self.client.call(arena.allocator(), "pane.place", .{ .pane = pane, .float = .{ .preset = preset } })) {
            .ok => {},
            .err => |code| self.say("pane.place: {s}", .{code}),
        }
    }
    /// Run a palette entry with JSON params (a `venomx` verb goes to the
    /// daemon; a `venom-desk` entry is a local action). Other products'
    /// verbs run through their own CLI, under their own authorization, as
    /// an `exec` would.
    pub fn runEntry(self: *Desk, entry: *const palette_mod.Entry, params: []const u8) !void {
        if (entry.local) |l| return self.local(l);
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        if (eq(u8, entry.tool, "venomx")) {
            switch (try self.client.callJson(a, entry.verb, params)) {
                .ok => {},
                .err => |code| self.say("{s}: {s}", .{ entry.verb, code }),
            }
            return;
        }
        // `<tool> <verb words…> --json` with params as `--name=value`.
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, entry.tool);
        var words = std.mem.splitScalar(u8, entry.verb, '.');
        while (words.next()) |w| try argv.append(a, w);
        const v = try std.json.parseFromSliceLeaky(Value, a, params, .{});
        if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |e| {
                const val = if (e.value_ptr.* == .string) e.value_ptr.string else try std.json.Stringify.valueAlloc(a, e.value_ptr.*, .{});
                try argv.append(a, try std.fmt.allocPrint(a, "--{s}={s}", .{ e.key_ptr.*, val }));
            }
        }
        try argv.append(a, "--json");
        const env = try keys.execEnviron(a, self.options.environ);
        if (self.options.exec) |f| f(self.options.exec_ctx, argv.items, env) else spawnDetached(a, argv.items, env) catch |err| try self.notice(.warn, "{s}: {s}", .{ entry.tool, @errorName(err) });
    }

    // -------------------------------------------------------- frame

    /// The rows below/above the status line, right of the rail when shown.
    pub fn windowArea(self: *const Desk) floats.Rect {
        const line: u16 = if (self.status_config.position == .off) 0 else 1;
        const rail: u16 = if (self.railRect()) |r| r.width else 0;
        return .{ .x = rail, .y = if (self.status_config.position == .top) line else 0, .width = self.options.cols - rail, .height = self.options.rows -| line };
    }
    /// Where the rail sits, its right border column included: the left
    /// edge, beside the panes. Null when hidden, or when the terminal is too
    /// narrow to give it `rail_width` and keep two thirds for the panes.
    pub fn railRect(self: *const Desk) ?floats.Rect {
        if (!self.view.rail or self.options.cols / 3 < rail_width) return null;
        const line: u16 = if (self.status_config.position == .off) 0 else 1;
        const height = self.options.rows -| line;
        if (height == 0) return null;
        return .{ .x = 0, .y = if (self.status_config.position == .top) line else 0, .width = rail_width, .height = height };
    }
    pub fn statusRow(self: *const Desk) ?u16 {
        return switch (self.status_config.position) {
            .top => 0,
            .bottom => self.options.rows -| 1,
            .off => null,
        };
    }
    /// `venomx.mode`, as `venomx attach` shows it: `LEADER`,
    /// `LEADER <table>`, `LOCK`, each prefixed by `NESTED` inside a venomx
    /// pane. Allocated in `a` when it is not a constant.
    pub fn modeText(self: *const Desk, a: std.mem.Allocator) ![]const u8 {
        const m = try self.router.modeText(a);
        if (!self.options.nested) return m;
        return if (m.len == 0) "NESTED" else std.fmt.allocPrint(a, "NESTED {s}", .{m});
    }
    /// The panes `venomx.panes` lists: the shown window's tiles in layout
    /// order, then a focused float or popup, as `venomx attach`.
    fn listedPanes(self: *const Desk, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var has_focus = false;
        if (self.currentWindow()) |w| for (w.nodes) |n| if (n.pane) |p| {
            try out.append(a, p);
            if (self.view.focus) |f| has_focus = has_focus or eq(u8, f, p);
        };
        if (!has_focus) if (self.view.focus) |f| if (self.state.pane(f) != null) try out.append(a, f);
        return out.items;
    }
    /// Status items with this client's view: what the
    /// status line and the rail both show.
    pub fn statusItems(self: *Desk, a: std.mem.Allocator) ![]status.Item {
        const ids = try self.windowIds(a);
        const windows = try a.alloc(status.Window, ids.len);
        for (ids, windows) |id, *w| w.* = .{ .id = id, .name = if (self.state.window(id)) |win| win.name else "" };
        return status.items(a, &self.state, self.status_config, .{
            .session = self.session,
            .windows = windows,
            .active = self.view.window,
            .focus = self.view.focus,
            .panes = try self.listedPanes(a),
            .zoomed = self.view.zoomed,
            .nested = self.options.nested,
            .mode = try self.router.modeText(a),
            .message = self.message.items,
            .clock = self.clock,
            .clock_now = self.clock_now,
            .now = self.now_ms,
            .host = self.host,
            .user = self.user,
            .toggled = @ptrCast(self.toggled.items),
            .cols = self.options.cols,
        });
    }
    pub fn statusPlaced(self: *Desk, a: std.mem.Allocator) ![]status.Placed {
        return status.layout(a, try self.statusItems(a), self.options.cols);
    }
    pub fn statusLine(self: *Desk, a: std.mem.Allocator) ![]u8 {
        return status.render(a, try self.statusPlaced(a), self.options.cols);
    }
    /// The rail's segment rows (groups as lists), all of
    /// them; `frame` shows those that fit.
    pub fn railRows(self: *Desk, a: std.mem.Allocator) ![]status.RailRow {
        return status.railRows(a, &self.state, try self.statusItems(a));
    }
    /// The rail's lines as drawn: a heading, then one row per segment, a
    /// group's members indented under its name.
    pub fn railLines(self: *Desk, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(a, "status");
        for (try self.railRows(a)) |r| try out.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ if (r.member) "  " else " ", r.text }));
        return out.items;
    }

    // -------------------------------------------------------- clicks

    /// A left click at a cell. On the status line or the rail
    /// it runs the clicked segment's (or group member's) target as this
    /// client, as a key press would; a segment without one does nothing,
    /// and the click never reaches a pane. True when the cell is the status
    /// line's or the rail's, so the caller does not pass it on.
    pub fn click(self: *Desk, x: u16, y: u16) !bool {
        if (!self.onChrome(x, y)) return false;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        const id: ?[]const u8 = if (self.statusRow() != null and y == self.statusRow().?)
            status.hit(try self.statusPlaced(a), x)
        else if (self.railRect()) |r| blk: {
            // Row 0 of the rail is its heading.
            const row = y - r.y;
            if (row == 0 or x + 1 == r.x + r.width) break :blk null;
            const rows = try self.railRows(a);
            break :blk if (row - 1 < rows.len) rows[row - 1].id else null;
        } else unreachable;
        if (id) |segment| try self.runClick(a, segment);
        return true;
    }
    /// The cell is the status line's or the rail's: mouse events there
    /// never reach a pane.
    pub fn onChrome(self: *const Desk, x: u16, y: u16) bool {
        if (self.statusRow()) |row| if (y == row) return true;
        const r = self.railRect() orelse return false;
        return x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
    }
    fn runClick(self: *Desk, a: std.mem.Allocator, id: []const u8) !void {
        const target = status.clickOf(self.status_config, &self.state, id) orelse return;
        switch (try keys.K.parseBinding(a, .{ .key = "a", .local = target.local, .verb = target.verb, .args = target.args, .exec = target.exec }, "click")) {
            .ok => |binding| try self.run(&binding.target),
            .failed => self.say("{s}: invalid click target", .{id}),
        }
    }
    /// Where each visible float of the shown window sits on this client.
    pub const FloatBox = struct { pane: *const shared.Pane, placement: floats.Placement, spec: floats.Spec, known_preset: bool };
    pub fn floatBoxes(self: *const Desk, a: std.mem.Allocator) ![]FloatBox {
        var out: std.ArrayList(FloatBox) = .empty;
        for (try self.windowFloats(a)) |p| {
            // `toggle-floats` hides the float layer; popups stay.
            if (!self.view.floats_visible and p.layer == .float) continue;
            const looked = self.presets.lookup(if (p.preset.len > 0) p.preset else null);
            const spec = p.geometry.over(looked.spec);
            try out.append(a, .{ .pane = p, .placement = floats.resolve(spec, self.windowArea()), .spec = spec, .known_preset = looked.known });
        }
        return out.toOwnedSlice(a);
    }

    /// A plain-text frame: the status line, the shown window's tiles (zoom
    /// fills the area with the focused pane), attention markers, floats in
    /// z-order and the active overlay. Pane content and the leader popup are
    /// the terminal layer's.
    pub fn frame(self: *Desk, a: std.mem.Allocator) ![]const []const u8 {
        var grid = try Grid.init(a, self.options.cols, self.options.rows);
        if (self.statusRow()) |row| grid.text(0, row, self.options.cols, try self.statusLine(a));
        if (self.railRect()) |r| {
            for (try self.railLines(a), 0..) |l, i| {
                if (i >= r.height) break;
                grid.text(r.x, r.y + @as(u16, @intCast(i)), r.width - 1, l);
            }
            for (0..r.height) |i| grid.text(r.x + r.width - 1, r.y + @as(u16, @intCast(i)), 1, "│");
        }
        const area = self.windowArea();
        if (self.currentWindow()) |w| {
            const ls = try tiling.leaves(a, w.nodes, area);
            for (ls) |leaf| {
                if (self.view.zoomed and (self.view.focus == null or !eq(u8, leaf.pane, self.view.focus.?))) continue;
                const r = if (self.view.zoomed) area else leaf.rect;
                try self.drawPane(&grid, a, leaf.pane, r, .single);
            }
        }
        for (try self.floatBoxes(a)) |b| {
            grid.clear(b.placement.rect);
            try self.drawPane(&grid, a, b.pane.id, b.placement.rect, b.spec.border);
            if (b.spec.title.len > 0 and b.placement.rect.width > 4) grid.text(b.placement.rect.x + 2, b.placement.rect.y, b.placement.rect.width - 4, b.spec.title);
        }
        switch (self.view.overlay) {
            .none => {},
            .palette => {
                const pv = try self.paletteView(a);
                try self.drawList(&grid, a, pv.title, pv.lines);
            },
            .inbox => try self.drawList(&grid, a, "inbox", try self.inboxLines(a)),
        }
        return grid.rows(a);
    }
    fn drawPane(self: *Desk, grid: *Grid, a: std.mem.Allocator, id: []const u8, r: floats.Rect, border: floats.Border) !void {
        if (border != .none) grid.box(r, border);
        const focused = self.view.focus != null and eq(u8, self.view.focus.?, id);
        const label = try std.fmt.allocPrint(a, "{s}{s}", .{ id, if (focused) "*" else "" });
        if (r.width > 2 and r.height > 2) grid.text(r.x + 1, r.y + 1, r.width - 2, label);
        // The attention marker, glyph plus level, on the pane's top edge.
        const p = self.state.pane(id) orelse return;
        if (p.level == .none or r.width == 0) return;
        const style = status.levelStyle(p.level);
        grid.text(r.x, r.y, r.width, try std.fmt.allocPrint(a, " {s} {s} ", .{ status.glyph(style), @tagName(p.level) }));
    }
    fn drawList(self: *Desk, grid: *Grid, a: std.mem.Allocator, title: []const u8, lines: []const []const u8) !void {
        _ = a;
        const area = self.windowArea();
        const spec: floats.Spec = .{ .width = .{ .percent = 50 }, .height = .{ .cells = @intCast(@min(lines.len + 2, area.height)) }, .anchor = .bottom, .min_cols = 10, .min_rows = 3 };
        const r = floats.resolve(spec, area).rect;
        grid.clear(r);
        grid.box(r, .rounded);
        if (r.width > 4) grid.text(r.x + 2, r.y, r.width - 4, title);
        for (lines, 0..) |l, i| {
            if (i + 2 >= r.height) break;
            grid.text(r.x + 2, r.y + 1 + @as(u16, @intCast(i)), r.width -| 4, l);
        }
    }
    pub fn paletteLines(self: *Desk, a: std.mem.Allocator, query: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.palette.filter(a, query)) |m| try out.append(a, try std.fmt.allocPrint(a, "{s}  {s}", .{ try m.entry.command(a), m.entry.summary }));
        return out.toOwnedSlice(a);
    }
    pub fn inboxLines(self: *Desk, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.history.inbox(a, &self.state, self.session)) |it| switch (it) {
            .attention => |p| try out.append(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ status.glyph(status.levelStyle(p.level)), p.id, p.reason })),
            .note => |n| try out.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ status.glyph(status.notifyStyle(n.level)), n.text })),
        };
        return out.toOwnedSlice(a);
    }
};

pub const workspace_tag = "workspace";
/// venomx takes pane tags as `[{key, value}]` (its `tags` param).
pub const TagPair = struct { key: []const u8, value: []const u8 };
fn workspaceTagsFor(name: []const u8) [1]TagPair {
    return .{.{ .key = workspace_tag, .value = name }};
}

/// Workspaces: a workspace is a venomx session, not a new
/// entity. Panes venom-desk creates in it carry the `workspace` tag with
/// the workspace name, so other products and clients can tell desk-managed
/// panes apart.
pub const Workspace = struct { session: []const u8, name: []const u8 };
pub fn listWorkspaces(a: std.mem.Allocator, client: Client) ![]Workspace {
    var out: std.ArrayList(Workspace) = .empty;
    switch (try client.call(a, "session.list", .{})) {
        .ok => |v| for (json.array(v, "sessions") orelse &.{}) |s| {
            const id = json.str(s, "session") orelse continue;
            try out.append(a, .{ .session = id, .name = json.str(s, "name") orelse id });
        },
        .err => return error.SessionListFailed,
    }
    return out.toOwnedSlice(a);
}
/// `session.create` plus a first window whose pane is tagged with the
/// workspace. Returns the session ID (in `a`).
pub fn createWorkspace(a: std.mem.Allocator, client: Client, name: []const u8, argv: []const []const u8) ![]const u8 {
    const s = switch (try client.call(a, "session.create", .{ .name = name })) {
        .ok => |v| json.str(v, "session") orelse return error.BadReply,
        .err => return error.SessionCreateFailed,
    };
    switch (try client.call(a, "window.create", .{ .session = s, .argv = argv, .tags = workspaceTagsFor(name) })) {
        .ok => {},
        .err => return error.WindowCreateFailed,
    }
    return s;
}

fn spawnDetached(a: std.mem.Allocator, argv: []const []const u8, env: []const []const u8) !void {
    _ = a;
    _ = argv;
    _ = env;
    // The terminal layer supplies `Options.exec` with its `std.Io`; the
    // headless core has none, so an unset hook is reported, not run.
    return error.NoExecHook;
}

/// Object IDs are a letter plus a decimal number; order numerically.
fn idLess(x: []const u8, y: []const u8) bool {
    const nx = std.fmt.parseInt(u64, if (x.len > 1) x[1..] else "", 10) catch return std.mem.lessThan(u8, x, y);
    const ny = std.fmt.parseInt(u64, if (y.len > 1) y[1..] else "", 10) catch return std.mem.lessThan(u8, x, y);
    return nx < ny;
}

/// A cell grid of UTF-8 code point slices.
const Grid = struct {
    cols: u16,
    rows_n: u16,
    cells: [][]const u8,

    fn init(a: std.mem.Allocator, cols: u16, rows_n: u16) !Grid {
        const cells = try a.alloc([]const u8, @as(usize, cols) * rows_n);
        @memset(cells, " ");
        return .{ .cols = cols, .rows_n = rows_n, .cells = cells };
    }
    fn set(self: *Grid, x: u16, y: u16, c: []const u8) void {
        if (x >= self.cols or y >= self.rows_n) return;
        self.cells[@as(usize, y) * self.cols + x] = c;
    }
    fn text(self: *Grid, x: u16, y: u16, max: u16, s: []const u8) void {
        var it = (std.unicode.Utf8View.init(s) catch return).iterator();
        var i: u16 = 0;
        while (it.nextCodepointSlice()) |cp| : (i += 1) {
            if (i >= max) break;
            self.set(x + i, y, cp);
        }
    }
    fn clear(self: *Grid, r: floats.Rect) void {
        var y = r.y;
        while (y < r.y + r.height) : (y += 1) {
            var x = r.x;
            while (x < r.x + r.width) : (x += 1) self.set(x, y, " ");
        }
    }
    fn box(self: *Grid, r: floats.Rect, border: floats.Border) void {
        if (r.width < 2 or r.height < 2 or border == .none) return;
        const g: [6][]const u8 = switch (border) {
            .single => .{ "┌", "┐", "└", "┘", "─", "│" },
            .rounded => .{ "╭", "╮", "╰", "╯", "─", "│" },
            .heavy => .{ "┏", "┓", "┗", "┛", "━", "┃" },
            .none => unreachable,
        };
        const right = r.x + r.width - 1;
        const bottom = r.y + r.height - 1;
        var x = r.x + 1;
        while (x < right) : (x += 1) {
            self.set(x, r.y, g[4]);
            self.set(x, bottom, g[4]);
        }
        var y = r.y + 1;
        while (y < bottom) : (y += 1) {
            self.set(r.x, y, g[5]);
            self.set(right, y, g[5]);
        }
        self.set(r.x, r.y, g[0]);
        self.set(right, r.y, g[1]);
        self.set(r.x, bottom, g[2]);
        self.set(right, bottom, g[3]);
    }
    fn rows(self: *const Grid, a: std.mem.Allocator) ![]const []const u8 {
        const out = try a.alloc([]const u8, self.rows_n);
        for (out, 0..) |*row, y| {
            var line: std.ArrayList(u8) = .empty;
            for (self.cells[y * self.cols .. (y + 1) * self.cols]) |c| try line.appendSlice(a, c);
            row.* = line.items;
        }
        return out;
    }
};
