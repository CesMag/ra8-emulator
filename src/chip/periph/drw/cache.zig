//! The DRW's two caches, both behind the one write-only CACHECTL register
//! (HUM Ch 62.2.4 p 3694): the framebuffer write-back cache and the texture
//! cache.
//!
//! This is the gap that mattered on dev. The HAL turns the framebuffer cache
//! ON before every stroked line and every triangle (ra8_drw_draw.c writes
//! CENABLEFX | CENABLETX | CFLUSHFX just ahead of the CONTROL/ORIGIN pair),
//! and board_periph_drw.c declines any render with CENABLEFX set, so every
//! line and every triangle the driver emitted came back to a blank
//! framebuffer and the app passed.
//!
//! WHAT IS MODELLED is where a rendered pixel IS. With the cache on, a
//! painted pixel is held here and is NOT in memory until a CFLUSHFX writes
//! it back, a read of that pixel is served from here rather than from the
//! stale word underneath (the blend path reads the destination before it
//! composites), and STATUS.CACHEDIRTY reports whether anything is held.
//!
//! NOT MODELLED, AND NOT GUESSED: the line geometry. HUM Ch 62.2.4 names the
//! two enables and the two flush pulses and says nothing about line size,
//! ways or replacement policy, so this holds whole pixel writes in a bounded
//! table and writes the oldest one back when it runs out of room. The bound
//! is this model's, not silicon's. What it buys is the observable rule, that
//! a pixel is not in memory until a flush, not a cycle count.
const std = @import("std");

const Guest = @import("../../core/cpu/memory/guest.zig").Guest;

/// CACHECTL bits (HUM Ch 62.2.4 p 3694). The enables are state, the two
/// flushes are write-one pulses, and the whole register is write-only.
pub const bits = struct {
    pub const enable_fb: u32 = 1 << 0;
    pub const flush_fb: u32 = 1 << 1;
    pub const enable_tx: u32 = 1 << 2;
    pub const flush_tx: u32 = 1 << 3;
};

/// STATUS bit this side owns (HUM Ch 62.2.5 p 3695).
pub const status = struct {
    pub const cache_dirty: u32 = 1 << 2;
};

pub const limits = struct {
    /// Pixel writes held before the oldest is written back. See the file
    /// header: a bound this model chose, not a cache line count.
    pub const cells: usize = 256;
};

/// One held pixel: where it goes, how wide it is, and what it holds.
const Cell = struct {
    at: u32,
    bytes: usize,
    value: u32,
};

/// The framebuffer cache: what the engine has painted but memory has not
/// been told about yet.
pub const Framebuffer = struct {
    enabled: bool = false,
    cells: [limits.cells]Cell = undefined,
    used: usize = 0,

    /// Pixel writes taken in here instead of into memory.
    held: u64 = 0,
    /// Pixels written back, by a flush or by making room.
    written_back: u64 = 0,
    /// Pixels written back because the table was full, which silicon does
    /// on a schedule of its own.
    evicted: u64 = 0,
    /// Destination reads answered from here that memory would have answered
    /// with the word the previous primitive left behind.
    forwarded: u64 = 0,
    flushes: u32 = 0,
    /// Write-backs the memory refused.
    faults: u32 = 0,
    /// Times the cache was switched off with pixels still held. Silicon
    /// leaves that undefined; these are written back rather than dropped,
    /// because inventing a loss the firmware cannot see helps nobody.
    disabled_dirty: u32 = 0,

    pub fn dirty(self: *const Framebuffer) bool {
        return self.used != 0;
    }

    pub fn quiet(self: *const Framebuffer) bool {
        return self.held == 0 and self.flushes == 0 and self.faults == 0;
    }

    /// A CACHECTL write. The flush pulse acts on what is held now, so it
    /// runs before the new enable state lands.
    pub fn control(self: *Framebuffer, memory: ?Guest, word: u32) void {
        if (word & bits.flush_fb != 0) self.flush(memory);
        const on = word & bits.enable_fb != 0;
        if (self.enabled and !on and self.dirty()) {
            self.disabled_dirty +%= 1;
            self.flush(memory);
        }
        self.enabled = on;
    }

    /// Write every held pixel back and empty the table.
    pub fn flush(self: *Framebuffer, memory: ?Guest) void {
        self.flushes +%= 1;
        var index: usize = 0;
        while (index < self.used) : (index += 1) self.writeBack(memory, self.cells[index]);
        self.used = 0;
    }

    /// Take a pixel write. True when the cache holds it and the caller must
    /// leave memory alone.
    pub fn store(self: *Framebuffer, memory: ?Guest, at: u32, bytes: usize, value: u32) bool {
        if (!self.enabled) return false;
        self.held +%= 1;
        if (self.find(at)) |index| {
            self.cells[index] = .{ .at = at, .bytes = bytes, .value = value };
            return true;
        }
        if (self.used == limits.cells) self.makeRoom(memory);
        self.cells[self.used] = .{ .at = at, .bytes = bytes, .value = value };
        self.used += 1;
        return true;
    }

    /// What this pixel currently is, when the cache is the one holding it.
    pub fn load(self: *Framebuffer, at: u32) ?u32 {
        const index = self.find(at) orelse return null;
        self.forwarded +%= 1;
        return self.cells[index].value;
    }

    /// Room for one more: the oldest held pixel goes to memory.
    fn makeRoom(self: *Framebuffer, memory: ?Guest) void {
        self.writeBack(memory, self.cells[0]);
        self.evicted +%= 1;
        std.mem.copyForwards(Cell, self.cells[0 .. self.used - 1], self.cells[1..self.used]);
        self.used -= 1;
    }

    fn writeBack(self: *Framebuffer, memory: ?Guest, cell: Cell) void {
        const target = memory orelse {
            self.faults +%= 1;
            return;
        };
        var slot = @as([4]u8, @splat(0));
        const span = slot[0..cell.bytes];
        pack(span, cell.value);
        target.write(cell.at, span) catch {
            self.faults +%= 1;
            return;
        };
        self.written_back +%= 1;
    }

    fn find(self: *const Framebuffer, at: u32) ?usize {
        var index: usize = 0;
        while (index < self.used) : (index += 1) {
            if (self.cells[index].at == at) return index;
        }
        return null;
    }
};

/// The texture cache. The texels themselves are read through on every
/// sample in tex.zig, which is the coherent case and the one the
/// driver's per-blit CFLUSHTX pulse is asking for, so this side carries the
/// enable and the flush count and nothing invented on top of them.
pub const Texture = struct {
    enabled: bool = false,
    flushes: u32 = 0,

    pub fn control(self: *Texture, word: u32) void {
        if (word & bits.flush_tx != 0) self.flushes +%= 1;
        self.enabled = word & bits.enable_tx != 0;
    }
};

/// A framebuffer cell is one, two or four little-endian bytes. Both the
/// write-back above and the rasterizer in drw.zig move pixels through this
/// shape, so the arithmetic is here once rather than in both.
pub fn pack(slot: []u8, value: u32) void {
    for (slot, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}

pub fn unpack(slot: []const u8) u32 {
    var value: u32 = 0;
    for (slot, 0..) |byte, index| value |= @as(u32, byte) << @intCast(index * 8);
    return value;
}
