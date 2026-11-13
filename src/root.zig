//! venom-desk: a presentation client of venomx. See desk.zig.
pub const desk = @import("desk.zig");
pub const Desk = desk.Desk;
pub const shared = @import("shared.zig");
pub const status = @import("status.zig");
pub const keys = @import("keys.zig");
pub const floats = @import("floats.zig");
pub const tiling = @import("tiling.zig");
pub const inbox = @import("inbox.zig");
pub const palette = @import("palette.zig");
pub const client = @import("client.zig");
pub const json = @import("json.zig");
/// Pane tags and `when` matching (venom-term `chrome.tags`).
pub const tags = @import("term_chrome").tags;

test {
    _ = json;
    _ = floats;
    _ = tiling;
    _ = shared;
    _ = status;
    _ = keys;
    _ = inbox;
    _ = palette;
    _ = client;
    _ = desk;
    _ = @import("desk_tests.zig");
}
