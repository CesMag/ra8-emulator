//! Shared settled detection for GLCDC scans and e-ink LUT completion.
const std = @import("std");
const Panel = @import("ra8_components").eink.Panel;

pub const Detector = struct {
    allocator: std.mem.Allocator,
    window_ns: u64 = 50_000_000,
    previous: ?[]u32 = null,
    width: u32 = 0,
    height: u32 = 0,
    changed_at: ?u64 = null,
    emitted: bool = false,
    eink_settled: u32 = 0,

    pub fn deinit(self: *Detector) void {
        if (self.previous) |pixels| self.allocator.free(pixels);
    }

    /// The first unchanged scan after a change starts the virtual-time window.
    pub fn observeFrame(self: *Detector, width: u32, height: u32, pixels: []const u32, now: u64) !bool {
        const count = std.math.mul(usize, width, height) catch return error.BadShape;
        if (width == 0 or height == 0 or pixels.len != count) return error.BadShape;
        const same = self.previous != null and self.width == width and self.height == height and
            sameImage(self.previous.?, pixels);
        if (!same) {
            if (self.previous) |old| self.allocator.free(old);
            self.previous = try self.allocator.dupe(u32, pixels);
            self.width = width;
            self.height = height;
            self.changed_at = now;
            self.emitted = false;
            return false;
        }
        const since = self.changed_at orelse now;
        if (!self.emitted and now -| since >= self.window_ns) {
            self.emitted = true;
            return true;
        }
        return false;
    }

    /// E-ink settles only after the LUT count advances and the film is idle.
    pub fn observeEink(self: *Detector, panel: *const Panel) bool {
        if (panel.film.settled == self.eink_settled) return false;
        self.eink_settled = panel.film.settled;
        return !panel.film.busy();
    }

    pub fn resetWait(_: *Detector) void {}
};

fn sameImage(previous: []const u32, current: []const u32) bool {
    if (previous.len != current.len) return false;
    for (previous, current) |before, after| {
        if (before & 0x00FF_FFFF != after & 0x00FF_FFFF) return false;
    }
    return true;
}
