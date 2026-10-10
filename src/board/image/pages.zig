//! The pages an image asks to have mapped.
//!
//! A PT_LOAD segment lands wherever the linker put it, and the memory behind
//! it is mapped a page at a time. Two segments of one image routinely share a
//! page: a small app's .text and its .data sit a few hundred bytes apart in
//! MRAM, so the page holding the end of one also holds the start of the next.
//! Asking the CPU model to map a page it already holds is refused outright,
//! which ends the load before the image is on the part at all, so every
//! segment's pages are collected and merged here and only whole, disjoint
//! ranges are handed over to be mapped.
const std = @import("std");
const elf = @import("elf.zig");
const loaded_image = @import("ra8_chip").core.loaded_image;

/// Bytes in a page. The CPU model maps at this granularity, so a range that
/// is not a whole number of these cannot be asked for.
pub const page_bytes: u32 = 0x1000;

/// How many disjoint ranges one image may ask for. A firmware image has a
/// handful of load segments (text, data, the option-setting and OTP windows),
/// and merging brings them below that again.
pub const capacity: usize = 16;

pub const Error = error{TooManyRanges};

/// A whole number of pages, from `base` up to but not including `end`.
/// `end` is 64-bit so a range reaching the top of the address space is still
/// expressible; `base` is where a map starts and stays 32-bit.
pub const Range = loaded_image.Range;

/// The merged set of page ranges an image needs.
pub const Set = struct {
    ranges: [capacity]Range = undefined,
    count: usize = 0,

    /// Claim the pages holding `span` bytes from `address`, absorbing every
    /// range already claimed that overlaps or abuts them. A zero-length
    /// segment still claims the page it sits on: the CPU model has to hold
    /// that page before anything can be written there.
    pub fn add(self: *Set, address: u32, span: u64) Error!void {
        var low: u64 = address & ~@as(u32, page_bytes - 1);
        var high: u64 = roundUp(@as(u64, address) + @max(span, 1));
        var kept: usize = 0;
        for (self.ranges[0..self.count]) |range| {
            if (range.end < low or @as(u64, range.base) > high) {
                self.ranges[kept] = range;
                kept += 1;
                continue;
            }
            low = @min(low, @as(u64, range.base));
            high = @max(high, range.end);
        }
        if (kept == capacity) return Error.TooManyRanges;
        self.ranges[kept] = .{ .base = @intCast(low), .end = high };
        self.count = kept + 1;
        std.mem.sort(Range, self.ranges[0..self.count], {}, lowerBase);
    }

    /// The ranges claimed, in address order.
    pub fn items(self: *const Set) []const Range {
        return self.ranges[0..self.count];
    }
};

/// Every page an image's load segments need, merged.
pub fn forImage(image: elf.Image) Error!Set {
    var set = Set{};
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        try set.add(segment.paddr, loadSpan(segment));
    }
    return set;
}

/// The bytes a segment needs mapped at its load address.
///
/// A segment that runs where it loads claims the larger of what it carries
/// and what it reserves: .bss is a load segment with no bytes in the file and
/// a memory size, and the page holding it still has to be mapped for the
/// firmware to zero it. A segment that runs somewhere else, .data copied out
/// of MRAM into SRAM at boot, leaves only its file bytes at the load address;
/// its .bss belongs to the run address, so claiming it there would ask for
/// MRAM past the end of the part (RA8EMU-400).
pub fn loadSpan(segment: elf.Segment) u64 {
    if (segment.paddr != segment.vaddr) return segment.bytes.len;
    return @max(segment.memsz, segment.bytes.len);
}

fn roundUp(address: u64) u64 {
    return (address + page_bytes - 1) & ~@as(u64, page_bytes - 1);
}

fn lowerBase(_: void, left: Range, right: Range) bool {
    return left.base < right.base;
}
