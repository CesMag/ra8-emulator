//! The region map of a firmware image: which board memory each section
//! lands in, how full each region is, and where the stack sits.
//!
//! WHAT IT IS FOR. The firmware's linker prints a usage table per MEMORY
//! region; this is the same answer, read off the linked image so the
//! debugger can show it beside the run. Regions carry the linker script's
//! names, so a row here and a row in the link log line up.
//!
//! .DATA COUNTS TWICE. An initialised section runs in SRAM and is stored in
//! MRAM, so it takes room in both. A section that is stored apart from where
//! it runs (sections.Section.stored with an LMA of its own) is placed by VMA
//! and again by LMA; zero-fill and no-init sections take room only where
//! they run.
//!
//! NOTHING IS DROPPED. A section that does not fit wholly inside one region
//! is counted as outside, with its bytes, so a bad link shows up here rather
//! than vanishing from the totals.
//!
//! THE STACK IS NOT A SECTION. The linker reserves it by symbol, below the
//! NOINIT carve-out, so it is reported beside the section usage and not
//! added into it: used still adds up to the section sizes.
//!
//! No heap: the firmware has none (no .heap region, and sbrk traps), so
//! there are no heap symbols to read.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const memmap = @import("ra8_chip").core.memmap;
const sections = @import("sections.zig");
const symbols = @import("symbols.zig");

/// One linker MEMORY region.
pub const Region = struct {
    name: []const u8,
    base: u32,
    size: u32,

    /// Whether the whole span [address, address + length) is inside.
    pub fn holds(self: Region, address: u32, length: u32) bool {
        const end = @as(u64, self.base) + self.size;
        return address >= self.base and @as(u64, address) + length <= end;
    }
};

/// The MEMORY block of libs/ra8_board_ek_ra8d2/ld/linker_script.ld, under
/// its own names. Bases come from the emulator's memory map where it has
/// them; sizes are the linker's, so SRAM stops 256 bytes short of 1 MiB and
/// NOINIT is its own region at the top.
pub const ek_ra8d2 = [_]Region{
    .{ .name = "MRAM", .base = memmap.mram_base, .size = 1024 * 1024 },
    .{ .name = "OFS_CFG", .base = 0x02C9_F000, .size = 2 * 1024 },
    .{ .name = "OFS_OTP", .base = 0x02E0_7000, .size = 68 * 1024 },
    .{ .name = "ITCM", .base = memmap.itcm_base, .size = 64 * 1024 },
    .{ .name = "DTCM", .base = memmap.dtcm_base, .size = 64 * 1024 },
    .{ .name = "SRAM", .base = memmap.sram_base, .size = 1024 * 1024 - 256 },
    .{ .name = "NOINIT", .base = memmap.sram_base + 1024 * 1024 - 256, .size = 256 },
    .{ .name = "SDRAM", .base = memmap.sdram_base, .size = 64 * 1024 * 1024 },
    .{ .name = "NS_MRAM", .base = memmap.ns_mram_base + 512 * 1024, .size = 512 * 1024 },
    .{ .name = "NS_SRAM", .base = memmap.ns_sram_base + 1024 * 1024, .size = 640 * 1024 },
};

/// The most regions one map holds; the EK-RA8D2 script has ten.
pub const max_regions = 16;

/// The linker symbols that reserve the main stack.
pub const stack_symbols = struct {
    pub const top = "g_ra8_ls_stack_top";
    pub const size = "g_ra8_ls_stack_size";
};

/// The stack reservation: [base, base + size), and the region it sits in.
pub const Stack = struct {
    base: u32,
    size: u32,
    region: ?usize,
};

pub const Error = error{TooManyRegions};

/// Section bytes per region, the sections that fit none, and the stack.
pub const Map = struct {
    regions: []const Region,
    used: [max_regions]u64 = @splat(0),
    outside: usize = 0,
    outside_bytes: u64 = 0,
    stack: ?Stack = null,

    /// Bytes left in a region; never below zero, even when overfilled.
    pub fn free(self: Map, index: usize) u64 {
        const size: u64 = self.regions[index].size;
        return size -| self.used[index];
    }

    /// The index of a region by its linker name.
    pub fn find(self: Map, name: []const u8) ?usize {
        for (self.regions, 0..) |region, index| {
            if (std.mem.eql(u8, region.name, name)) return index;
        }
        return null;
    }

    fn place(self: *Map, address: u32, length: u32) void {
        if (regionAt(self.regions, address, length)) |index| {
            self.used[index] += length;
        } else if (length != 0) {
            self.outside += 1;
            self.outside_bytes += length;
        }
    }
};

/// The first region that holds the whole span, or null.
pub fn regionAt(regions: []const Region, address: u32, length: u32) ?usize {
    for (regions, 0..) |region, index| {
        if (region.holds(address, length)) return index;
    }
    return null;
}

/// Place every allocated section of the image in the regions, and find the
/// stack reservation from its linker symbols.
pub fn build(image: elf.Image, regions: []const Region) Error!Map {
    if (regions.len > max_regions) return Error.TooManyRegions;
    var map = Map{ .regions = regions };
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const found = sections.read(image, index) orelse continue;
        map.place(found.vma, found.size);
        if (found.stored() and found.lma != found.vma) map.place(found.lma, found.size);
    }
    map.stack = stackOf(image, regions);
    return map;
}

/// The main stack reservation the image's linker symbols name, if any.
pub fn stackOf(image: elf.Image, regions: []const Region) ?Stack {
    const top = symbols.addressOf(image, stack_symbols.top) orelse return null;
    const size = symbols.addressOf(image, stack_symbols.size) orelse return null;
    if (size > top) return null;
    const base = top - size;
    return .{ .base = base, .size = size, .region = regionAt(regions, base, size) };
}
