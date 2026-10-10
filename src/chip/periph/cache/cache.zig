//! The SCB cache window: the geometry the firmware reads, and the
//! maintenance it asks for.
//!
//! `ra8_cache.c` drives eleven words in the PPB at 0xE000Exxx. The PPB is
//! plain RAM in this tree, so every one of them read as zero and a
//! maintenance store landed in a word nothing looked at. Two consequences,
//! one of them with teeth:
//!
//!   CTR read as zero, so `ra8_cache_dcache_line_bytes` answered four bytes
//!   instead of the 32 this core has. Every by-address maintenance call then
//!   did eight times the work: a clean over a 4 KiB DMA buffer wrote DCCMVAC
//!   1024 times rather than 128, inside a budget the run has to finish in.
//!   `ra8_spi_b_dma.c` rounds its staging buffers to the same number, so the
//!   wrong line size mis-sized those too.
//!
//!   Nothing could see that maintenance happened at all. The registers are
//!   write-only on silicon, and against RAM a write is indistinguishable
//!   from the zero already there.
//!
//! This block is a watcher on the PPB, like AIRCR in scb.zig and for the same
//! reason: the cache words are not on the peripheral bus, so they are primed
//! at attach and read at the chunk boundary rather than hooked per access.
//! The cost is the same one: an operation is noticed at the end of the chunk
//! it happened in, and a hundred stores inside one chunk are seen as one. The
//! report says boundaries, not stores, because boundaries is what this seam
//! can honestly count.
//!
//! Each maintenance register is primed with a sentinel rather than zero, so a
//! write of zero is still visible. 0xFFFFFFFF is safe as that sentinel: a
//! by-MVA register takes a line-aligned address and a set/way register takes
//! `(set << 5) | (way << 30)`, so neither can carry the low five bits the
//! sentinel sets, and ICIALLU is only ever written with zero.
//!
//!   CTR      0xE000ED7C  read-only, primed, a store is refused
//!   CCSIDR   0xE000ED80  read-only, primed, a store is refused
//!   CSSELR   0xE000ED84  read/write, the cache the walk selected
//!   CCR      0xE000ED14  read/write, watched for IC and DC
//!   ICIALLU  0xE000EF50  write-only, I-cache invalidate all
//!   DCIMVAC  0xE000EF5C  write-only, D-cache invalidate by address
//!   DCISW    0xE000EF60  write-only, D-cache invalidate by set/way
//!   DCCMVAC  0xE000EF68  write-only, D-cache clean by address
//!   DCCIMVAC 0xE000EF70  write-only, D-cache clean and invalidate by address
//!   DCCISW   0xE000EF74  write-only, D-cache clean+invalidate by set/way
const memmap = @import("../../core/memmap.zig");

pub const geometry = @import("geometry.zig");

/// The word primed into every maintenance register, and what one still
/// reading it means: nothing was written to it this chunk.
pub const idle: u32 = 0xFFFF_FFFF;

/// The maintenance operations, in the order they are reported.
pub const Op = enum(u3) {
    icache_all,
    invalidate,
    invalidate_set_way,
    clean,
    clean_invalidate,
    clean_invalidate_set_way,

    pub fn address(self: Op) u32 {
        return switch (self) {
            .icache_all => memmap.cache.iciallu,
            .invalidate => memmap.cache.dcimvac,
            .invalidate_set_way => memmap.cache.dcisw,
            .clean => memmap.cache.dccmvac,
            .clean_invalidate => memmap.cache.dccimvac,
            .clean_invalidate_set_way => memmap.cache.dccisw,
        };
    }

    pub fn name(self: Op) []const u8 {
        return switch (self) {
            .icache_all => "I-cache invalidate all",
            .invalidate => "D-cache invalidate by address",
            .invalidate_set_way => "D-cache invalidate by set/way",
            .clean => "D-cache clean by address",
            .clean_invalidate => "D-cache clean and invalidate by address",
            .clean_invalidate_set_way => "D-cache clean and invalidate by set/way",
        };
    }
};

pub const op_count = @typeInfo(Op).@"enum".field_names.len;

/// What the cache window holds and what the firmware has asked it for.
pub const Cache = struct {
    /// The read-only geometry, as primed.
    ctr: u32 = geometry.reportedCtr(),
    ccsidr: u32 = geometry.ccsidr.unavailable,
    /// CSSELR: which cache a walk last selected.
    selected: u32 = 0,
    /// Boundaries at which each operation was seen, one counter per Op.
    seen: [op_count]u32 = @splat(0),
    /// Stores to CTR or CCSIDR, which are read-only on silicon.
    refused: u32 = 0,
    /// CCR.IC and CCR.DC as last read, and how often that changed.
    enables: u32 = 0,
    changes: u32 = 0,

    pub fn init() Cache {
        return .{};
    }

    /// A run whose firmware never touched the cache stays out of the report.
    pub fn quiet(self: *const Cache) bool {
        return self.total() == 0 and self.refused == 0 and self.changes == 0;
    }

    /// Every maintenance boundary counted, whatever the operation.
    pub fn total(self: *const Cache) u32 {
        var sum: u32 = 0;
        for (self.seen) |boundaries| sum +%= boundaries;
        return sum;
    }

    pub fn count(self: *const Cache, which: Op) u32 {
        return self.seen[@backingInt(which)];
    }

    /// Boundaries at which a whole-cache set/way walk was asked for, either
    /// spelling of it.
    pub fn setWayAsked(self: *const Cache) u32 {
        return self.count(.invalidate_set_way) +% self.count(.clean_invalidate_set_way);
    }

    /// The line size the firmware reads out of this window, in bytes.
    pub fn lineBytes(self: *const Cache) u32 {
        return geometry.lineBytes(self.ctr);
    }

    /// Whether the whole-cache walk declines for want of a geometry. True
    /// here by construction, and the report says so where it matters.
    pub fn walkDeclined(self: *const Cache) bool {
        return geometry.unavailable(self.ccsidr);
    }

    pub fn icacheOn(self: *const Cache) bool {
        return self.enables & geometry.ccr.icache != 0;
    }

    pub fn dcacheOn(self: *const Cache) bool {
        return self.enables & geometry.ccr.dcache != 0;
    }

    /// Put the read-only geometry and the maintenance sentinels in place, so
    /// the firmware's first read of CTR is this core's line size rather than
    /// the zero the mapping starts at.
    pub fn prime(self: *Cache, core: anytype) !void {
        try core.writeWord(memmap.cache.ctr, self.ctr);
        try core.writeWord(memmap.cache.ccsidr, self.ccsidr);
        inline for (@typeInfo(Op).@"enum".field_values) |value| {
            try core.writeWord((@as(Op, @fromBackingInt(@intCast(value)))).address(), idle);
        }
    }

    /// Read the window, count what the firmware did to it, and leave every
    /// register reading the way silicon would leave it.
    pub fn poll(self: *Cache, core: anytype) !void {
        try self.readOnly(core, memmap.cache.ctr, self.ctr);
        try self.readOnly(core, memmap.cache.ccsidr, self.ccsidr);
        self.selected = try core.readWord(memmap.cache.csselr);
        const ccr = try core.readWord(memmap.scb.ccr) & geometry.ccr.both;
        if (ccr != self.enables) {
            self.enables = ccr;
            self.changes +%= 1;
        }
        inline for (@typeInfo(Op).@"enum".field_values) |value| {
            const which: Op = @fromBackingInt(@intCast(value));
            if (try core.readWord(which.address()) != idle) {
                self.seen[value] +%= 1;
                try core.writeWord(which.address(), idle);
            }
        }
    }

    /// One read-only register: a firmware store to it is turned away and the
    /// architectural value put back.
    fn readOnly(self: *Cache, core: anytype, at: u32, value: u32) !void {
        if (try core.readWord(at) == value) return;
        self.refused +%= 1;
        try core.writeWord(at, value);
    }
};
