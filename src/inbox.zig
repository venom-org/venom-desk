//! Notification history and the inbox: the
//! daemon keeps only a bounded queue of 64; venom-desk keeps its own longer
//! history, and an inbox of what still needs the human: undismissed
//! notifications plus every pane with attention. Dismissing is local to
//! this client unless `all` is asked for, which is the `notify.dismiss
//! --all` verb.
const std = @import("std");
const shared = @import("shared.zig");
const eq = std.mem.eql;

pub const max_history = 512;

pub const Entry = struct {
    id: []u8,
    text: []u8,
    level: shared.NotifyLevel,
    pane: []u8,
    namespace: []u8,
    at: i64,
    read: bool = false,
    dismissed: bool = false,
    fn deinit(self: *Entry, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.text);
        a.free(self.pane);
        a.free(self.namespace);
    }
};

pub const Item = union(enum) {
    note: *const Entry,
    attention: *const shared.Pane,
};

pub const History = struct {
    a: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(a: std.mem.Allocator) History {
        return .{ .a = a };
    }
    pub fn deinit(self: *History) void {
        for (self.entries.items) |*e| e.deinit(self.a);
        self.entries.deinit(self.a);
    }
    /// Record a posted notification (from `shared.Change.posted`). A repost
    /// of the same id replaces the entry.
    pub fn record(self: *History, note: *const shared.Note, now: i64) !void {
        var e: Entry = .{ .id = &.{}, .text = &.{}, .level = note.level, .pane = &.{}, .namespace = &.{}, .at = now };
        errdefer e.deinit(self.a);
        e.id = try self.a.dupe(u8, note.id);
        e.text = try self.a.dupe(u8, note.text);
        e.pane = try self.a.dupe(u8, note.pane);
        e.namespace = try self.a.dupe(u8, note.namespace);
        for (self.entries.items, 0..) |*old, i| if (eq(u8, old.id, note.id)) {
            old.deinit(self.a);
            _ = self.entries.orderedRemove(i);
            break;
        };
        try self.entries.append(self.a, e);
        if (self.entries.items.len > max_history) {
            var old = self.entries.orderedRemove(0);
            old.deinit(self.a);
        }
    }
    pub fn find(self: *const History, id: []const u8) ?*Entry {
        for (self.entries.items) |*e| if (eq(u8, e.id, id)) return e;
        return null;
    }
    /// Local dismiss: hidden from this client's inbox, kept in history.
    pub fn dismiss(self: *History, id: []const u8) bool {
        const e = self.find(id) orelse return false;
        e.dismissed = true;
        e.read = true;
        return true;
    }
    pub fn markAllRead(self: *History) void {
        for (self.entries.items) |*e| e.read = true;
    }
    pub fn unread(self: *const History) usize {
        var n: usize = 0;
        for (self.entries.items) |e| if (!e.read and !e.dismissed) {
            n += 1;
        };
        return n;
    }
    /// The inbox, newest first: panes needing attention in `session`
    /// (most urgent first), then undismissed notifications.
    pub fn inbox(self: *const History, a: std.mem.Allocator, state: *const shared.State, session: []const u8) ![]Item {
        var out: std.ArrayList(Item) = .empty;
        var level: usize = 4;
        while (level > 1) {
            level -= 1;
            for (state.panes.items) |*p| if (@backingInt(p.level) == level and eq(u8, p.session, session)) try out.append(a, .{ .attention = p });
        }
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.entries.items[i];
            if (!e.dismissed) try out.append(a, .{ .note = e });
        }
        return out.toOwnedSlice(a);
    }
};

test "history outlives the daemon queue and dismiss is local" {
    const a = std.testing.allocator;
    var state = shared.State.init(a);
    defer state.deinit();
    var h = History.init(a);
    defer h.deinit();
    var i: usize = 0;
    while (i < shared.max_notifications + 10) : (i += 1) {
        const line = try std.fmt.allocPrint(a, "{{\"type\":\"notify.posted\",\"data\":{{\"id\":\"n{d}\",\"text\":\"t{d}\",\"ttl_ms\":10}}}}", .{ i, i });
        defer a.free(line);
        const ch = try shared.applyLine(&state, line, 0);
        try h.record(&state.notes.items[ch.posted], 0);
    }
    // The daemon mirror is bounded at 64 and expires; the history is not.
    try std.testing.expectEqual(@as(usize, shared.max_notifications), state.notes.items.len);
    try std.testing.expect(state.newest(100) == null);
    try std.testing.expectEqual(@as(usize, shared.max_notifications + 10), h.entries.items.len);
    try std.testing.expectEqual(@as(usize, shared.max_notifications + 10), h.unread());
    try std.testing.expect(h.dismiss("n3"));
    try std.testing.expect(h.find("n3") != null);

    _ = try shared.applyLine(&state, "{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p1\",\"level\":\"warn\"}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"pane.created\",\"data\":{\"pane\":\"p2\",\"session\":\"s0\"}}", 0);
    _ = try shared.applyLine(&state, "{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p2\",\"level\":\"urgent\"}}", 0);
    const items = try h.inbox(a, &state, "s0");
    defer a.free(items);
    // p2 (urgent, in s0) first; p1 has no session so it is not this session's.
    try std.testing.expectEqualStrings("p2", items[0].attention.id);
    try std.testing.expectEqualStrings("n73", items[1].note.id);
    for (items) |it| if (it == .note) try std.testing.expect(!eq(u8, it.note.id, "n3"));
}
