//! The on-chip memory geometry of each part, every value cited.
//!
//! Capacities are the function-comparison rows of each datasheet for the
//! dual-core MIPI part the emulator models (the "K" column): RA8D2
//! R01DS0493EJ0130 Table 1.14 p 11, RA8P1 R01DS0439EJ0130 Table 1.15 p 11.
//! The two rows are identical: 1 MB code MRAM, 1664 KB SRAM, 256 KB CPU0 TCM,
//! 128 KB CPU1 TCM and 32 KB of cache on each core. The single-core parts
//! carry 1792 KB SRAM and no CPU1 TCM or cache; neither is modelled.
//!
//! The per-bank split (ITCM/DTCM 128 + 128, CTCM/STCM 64 + 64, caches
//! 16 + 16) is RA8D2 HUM R01UH1065EJ0130 2.1.1 pp 111-112. The RA8P1 HUM is
//! not in hand, so its split is taken from the RA8D2's; that is sound only
//! because the datasheet totals match and the split multiplies out to them.
//! Bases are the ones src/chip/core/memmap.zig maps, which the firmware's
//! ra8_device.h records as byte-identical on both parts.

const memmap = @import("../memmap.zig");
const Part = @import("part.zig").Part;

const kib: u32 = 1024;

pub const Geometry = struct {
    mram_base: u32,
    mram_bytes: u32,
    sram_base: u32,
    sram_bytes: u32,
    /// CPU0 (Cortex-M85) ITCM and DTCM, each.
    cpu0_tcm_bank_bytes: u32,
    /// CPU0 I-cache and D-cache, each.
    cpu0_cache_bank_bytes: u32,
    /// CPU1 (Cortex-M33) CTCM and STCM, each.
    cpu1_tcm_bank_bytes: u32,
    /// CPU1 C-Cache and S-Cache (Renesas bus caches), each.
    cpu1_cache_bank_bytes: u32,
    /// Where the capacities come from.
    source: []const u8,

    pub fn cpu0TcmBytes(self: Geometry) u32 {
        return 2 * self.cpu0_tcm_bank_bytes;
    }

    pub fn cpu1TcmBytes(self: Geometry) u32 {
        return 2 * self.cpu1_tcm_bank_bytes;
    }
};

const dual_core = Geometry{
    .mram_base = 0x0200_0000,
    .mram_bytes = 1024 * kib,
    .sram_base = memmap.sram_base,
    .sram_bytes = 1664 * kib,
    .cpu0_tcm_bank_bytes = 128 * kib,
    .cpu0_cache_bank_bytes = 16 * kib,
    .cpu1_tcm_bank_bytes = 64 * kib,
    .cpu1_cache_bank_bytes = 16 * kib,
    .source = undefined,
};

fn with(source: []const u8) Geometry {
    var geometry = dual_core;
    geometry.source = source;
    return geometry;
}

/// The geometry of `part`.
pub fn of(part: Part) Geometry {
    return switch (part) {
        .ra8d2 => with("RA8D2 DS R01DS0493EJ0130 Table 1.14 p 11; HUM R01UH1065EJ0130 2.1.1"),
        .ra8p1 => with("RA8P1 DS R01DS0439EJ0130 Table 1.15 p 11; split from RA8D2 HUM 2.1.1"),
    };
}
