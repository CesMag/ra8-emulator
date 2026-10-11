//! Whether a frame needs presenting (RA8EMU-732, ADR 0001 in the knowledge base, RA8EMU-A-8
//! decision 3). The host loop builds its draw list every tick but presents
//! only when the list differs from the last one presented, or a resize or
//! expose forced a redraw, and never closer together than the platform's
//! interval: zero under vsync, which paces presents itself.
const std = @import("std");
const render = @import("ra8_render");
const draw_list = render.draw_list;

/// The cap when the display gives no vsync: one present per 60 Hz refresh.
pub const default_interval_ns: u64 = std.time.ns_per_s / 60;

pub const Gate = struct {
    /// The digest of the last list presented; null before the first.
    shown: ?u64 = null,
    forced: bool = true,
    last_ns: ?i128 = null,

    /// The next frame presents even if its list is unchanged.
    pub fn force(self: *Gate) void {
        self.forced = true;
    }

    /// Whether the list hashed to `list_hash` presents at `now_ns`.
    pub fn due(self: *const Gate, list_hash: u64, now_ns: i128, interval_ns: u64) bool {
        if (!self.forced and self.shown == list_hash) return false;
        const last = self.last_ns orelse return true;
        return now_ns - last >= interval_ns;
    }

    pub fn presented(self: *Gate, list_hash: u64, now_ns: i128) void {
        self.shown = list_hash;
        self.forced = false;
        self.last_ns = now_ns;
    }
};

/// Every command, clip and size in `list`, and each image's pixels by
/// content: the board view refills one buffer in place every tick, so a
/// pointer would hide its changes.
pub fn digest(list: *const draw_list.DrawList) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, list.bounds);
    for (list.commands.items) |command| {
        std.hash.autoHash(&hasher, command.clip);
        std.hash.autoHash(&hasher, std.meta.activeTag(command.shape));
        switch (command.shape) {
            .image => |quad| {
                std.hash.autoHash(&hasher, quad.area);
                std.hash.autoHash(&hasher, quad.image.width);
                std.hash.autoHash(&hasher, quad.image.height);
                hasher.update(std.mem.sliceAsBytes(quad.image.pixels));
            },
            inline else => |shape| std.hash.autoHash(&hasher, shape),
        }
    }
    const hash = hasher.final();
    return hash;
}
