//! Tests for src/chip/core/memmap.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.core.memmap;

const dwt = mod.dwt;
const nvic = mod.nvic;
const ppb_base = mod.ppb_base;
const ppb_size = mod.ppb_size;
const initiatorHolds = mod.initiatorHolds;
const ram = mod.ram;
const scb = mod.scb;
const syst = mod.syst;
test "every named PPB register falls inside the PPB window" {
    inline for (.{ scb, syst, nvic, dwt }) |block| {
        inline for (@typeInfo(block).@"struct".decl_names) |name| {
            const address = @field(block, name);
            try std.testing.expect(address >= ppb_base);
            try std.testing.expect(address < ppb_base + ppb_size);
        }
    }
}

test "the M85 ITCM window spans the 64 KiB linked by the board and is not mapped" {
    try std.testing.expectEqual(@as(u32, 0), mod.itcm_base);
    try std.testing.expectEqual(@as(u32, 0x1_0000), mod.itcm_end - mod.itcm_base);
    try std.testing.expect(!mod.debugHolds(mod.itcm_base, 4));
    try std.testing.expect(!initiatorHolds(mod.itcm_base, 4));
}

test "the PPB does not overlap the peripheral window" {
    try std.testing.expect(ppb_base > 0x4000_0000 + 0x1000_0000);
}

test "regions are ordered, non-overlapping and page aligned" {
    var previous_end: u64 = 0;
    for (ram) |region| {
        try std.testing.expect(region.base >= previous_end);
        try std.testing.expectEqual(@as(u32, 0), region.base % 0x1000);
        try std.testing.expectEqual(@as(u32, 0), region.size % 0x1000);
        previous_end = region.end();
    }
}

test "a bus initiator reaches the SRAM and both SDRAM aliases" {
    try std.testing.expect(initiatorHolds(mod.sram_base, 4));
    try std.testing.expect(initiatorHolds(mod.sram_end - 4, 4));
    try std.testing.expect(initiatorHolds(mod.sdram_base, 4));
    try std.testing.expect(initiatorHolds(mod.sdram_end - 4, 4));
    try std.testing.expect(initiatorHolds(mod.ns_sdram_base, 4));
    try std.testing.expect(initiatorHolds(mod.ns_sdram_end - 4, 4));
}

test "a bus initiator does not reach the core's own TCM" {
    try std.testing.expect(!initiatorHolds(mod.dtcm_base, 4));
    try std.testing.expect(!initiatorHolds(mod.dtcm_end - 4, 4));
}

test "the peripheral window and the PPB are not somewhere a frame lives" {
    try std.testing.expect(!initiatorHolds(0x4000_0000, 4));
    try std.testing.expect(!initiatorHolds(mod.ppb_base, 4));
}

test "a span that runs off the end of a window is not held by it" {
    try std.testing.expect(!initiatorHolds(mod.sram_end - 2, 4));
    try std.testing.expect(!initiatorHolds(mod.sdram_end - 2, 4));
    try std.testing.expect(!initiatorHolds(0xFFFF_FFFC, 8));
}

test "an empty span is nowhere" {
    try std.testing.expect(!initiatorHolds(mod.sram_base, 0));
}

test "the window a bus initiator address sits in comes back whole" {
    try std.testing.expectEqual(mod.sram_end, mod.initiatorWindow(mod.sram_base).?.end);
    try std.testing.expectEqual(mod.sram_base, mod.initiatorWindow(mod.sram_end - 1).?.base);
    try std.testing.expectEqual(mod.sdram_end, mod.initiatorWindow(mod.sdram_base).?.end);
    try std.testing.expectEqual(mod.ns_sdram_end, mod.initiatorWindow(mod.ns_sdram_base).?.end);
}

test "an address in no initiator window sits in none" {
    try std.testing.expect(mod.initiatorWindow(mod.dtcm_base) == null);
    try std.testing.expect(mod.initiatorWindow(mod.sram_end) == null);
    try std.testing.expect(mod.initiatorWindow(mod.sdram_end) == null);
    try std.testing.expect(mod.initiatorWindow(0x4000_0000) == null);
}

test "the debug window list carries the DTCM the initiator list leaves out" {
    try std.testing.expect(mod.debugHolds(mod.dtcm_base, 16));
    try std.testing.expect(!initiatorHolds(mod.dtcm_base, 16));
}

test "the debug window list carries every RAM the loader maps" {
    try std.testing.expect(mod.debugHolds(mod.sram_base, 16));
    try std.testing.expect(mod.debugHolds(mod.sdram_base, 16));
    try std.testing.expect(mod.debugHolds(mod.ns_sdram_base, 16));
}

test "the debug window list stops at the peripheral bus" {
    try std.testing.expect(!mod.debugHolds(0x4000_0000, 4));
    try std.testing.expect(!mod.debugHolds(ppb_base, 4));
}

test "the system SRAM is the full 1664 KB both parts carry" {
    try std.testing.expectEqual(@as(u32, 0x001A_0000), mod.sram_end - mod.sram_base);
}

test "a stack top at the very top of SRAM is held" {
    try std.testing.expect(mod.initiatorHolds(mod.sram_end - 8, 8));
}

test "the upper 640 KB an RA8D2 script calls NS_SRAM is the same memory" {
    try std.testing.expectEqual(mod.initiatorWindow(mod.sram_base).?.end, mod.initiatorWindow(0x2210_0000).?.end);
}

test "the Non-secure alias sits one IDAU bit above its Secure region" {
    try std.testing.expectEqual(@as(u32, 0x1000_0000), mod.ns_offset);
    try std.testing.expectEqual(@as(u32, 0x3200_0000), mod.ns_sram_base);
    try std.testing.expectEqual(@as(u32, 0x7800_0000), mod.ns_sdram_base);
    // An alias covers exactly the bytes it is an alias of.
    try std.testing.expectEqual(mod.sram_end - mod.sram_base, mod.ns_sram_end - mod.ns_sram_base);
    try std.testing.expectEqual(mod.sdram_end - mod.sdram_base, mod.ns_sdram_end - mod.ns_sdram_base);
}

test "the marker CPU1 writes through the alias lands in a mapped region" {
    // cpu1_pingpong_ipc's first probe word, written at the top of the CPU1
    // reset handler before the SAU is programmed. An unmapped store here
    // ended the run four instructions into the image.
    const marker: u32 = 0x3210_0200;
    var mapped = false;
    for (ram) |region| {
        if (marker >= region.base and marker + 4 <= region.end()) mapped = true;
    }
    try std.testing.expect(mapped);
    // The same image also marks the Secure view, so both have to answer.
    try std.testing.expect(initiatorHolds(marker, 4));
    try std.testing.expect(initiatorHolds(0x2219_0200, 4));
}

test "a debug probe and a bus initiator both reach the Non-secure SRAM view" {
    try std.testing.expect(initiatorHolds(mod.ns_sram_base, 4));
    try std.testing.expect(initiatorHolds(mod.ns_sram_end - 4, 4));
    try std.testing.expect(mod.debugHolds(mod.ns_sram_base, 4));
    try std.testing.expect(mod.debugHolds(mod.ns_sram_end - 4, 4));
    // One past the alias is nobody's.
    try std.testing.expect(!initiatorHolds(mod.ns_sram_end, 4));
}

test "the code MRAM region is the part map's 1 MB at its base" {
    const geometry = ra8.chip.core.part.map.of(.ra8d2);
    try std.testing.expectEqual(geometry.mram_base, mod.mram_base);
    try std.testing.expectEqual(geometry.mram_bytes, mod.mram_end - mod.mram_base);
    try std.testing.expectEqualStrings("MRAM", ram[0].name);
    for (ram) |region| try std.testing.expect(region.base != mod.itcm_base);
}

test "the Non-secure MRAM view is code MRAM one IDAU bit up (RA8EMU-412)" {
    try std.testing.expectEqual(@as(u32, 0x1200_0000), mod.ns_mram_base);
    try std.testing.expectEqual(mod.mram_end - mod.mram_base, mod.ns_mram_end - mod.ns_mram_base);
    try std.testing.expect(mod.ns_mram_end <= mod.dtcm_base);
}

test "coversRam answers for the part's RAM regions and nothing else" {
    try std.testing.expect(mod.coversRam(mod.sram_base, 4));
    try std.testing.expect(mod.coversRam(mod.ns_sram_base, 4));
    try std.testing.expect(mod.coversRam(mod.ppb_base, 4));
    // The whole code MRAM is RAM, so a page an image never loads
    // still answers.
    try std.testing.expect(mod.coversRam(mod.mram_base + 0x8_1000, 4));
    try std.testing.expect(!mod.coversRam(mod.mram_end - 2, 4));
    // A span running off the end of a region is not covered by it.
    try std.testing.expect(!mod.coversRam(mod.sram_end - 2, 4));
}
