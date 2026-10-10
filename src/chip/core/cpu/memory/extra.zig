//! Windows outside src/chip/core/memmap.zig that a peripheral maps at attach
//! (RA8EMU-487): the MRAM option window (mram/window.zig) and the TSN
//! calibration page (adc/tsn_cal.zig). The engine maps them on demand; the
//! store keeps them here so both backends answer the same addresses.
//!
//! A RANGE IS MAPPED ONCE. Mapping a range that touches one already held
//! fails with Mapped, the way the engine refuses a page it already holds,
//! so a caller that fills a fresh window leaves an earlier one's bytes.
const std = @import("std");

pub const Error = error{ Mapped, Full, OutOfMemory };

/// Room for every page the board maps. The MRAM option window maps one
/// window per page (17 of them, mram/window.zig), the TSN page is one more,
/// and an image's segments outside memmap take the rest. At 8 the option
/// window alone filled it, so an image page there failed to map (RA8EMU-580).
pub const capacity = 32;

const Window = struct {
    base: u32,
    bytes: []u8,

    fn end(self: Window) u64 {
        return @as(u64, self.base) + self.bytes.len;
    }
};

pub const Extra = struct {
    windows: [capacity]?Window = @splat(null),

    /// Back `size` zeroed bytes at `base`.
    pub fn map(self: *Extra, base: u32, size: u32) Error!void {
        var free: ?usize = null;
        for (self.windows, 0..) |held, index| {
            const window = held orelse {
                if (free == null) free = index;
                continue;
            };
            if (base < window.end() and window.base < @as(u64, base) + size) return Error.Mapped;
        }
        const slot = free orelse return Error.Full;
        const bytes = std.heap.page_allocator.alloc(u8, size) catch return Error.OutOfMemory;
        @memset(bytes, 0);
        self.windows[slot] = .{ .base = base, .bytes = bytes };
    }

    /// Host bytes for `len` bytes at `address`, or null when they are not
    /// all inside one window.
    pub fn span(self: *const Extra, address: u32, len: usize) ?[]u8 {
        for (self.windows) |held| {
            const window = held orelse continue;
            if (address < window.base or address >= window.end()) continue;
            const offset = address - window.base;
            if (len > window.bytes.len - offset) return null;
            return window.bytes[offset..][0..len];
        }
        return null;
    }

    pub fn deinit(self: *Extra) void {
        for (&self.windows) |*held| {
            if (held.*) |window| std.heap.page_allocator.free(window.bytes);
            held.* = null;
        }
    }
};
