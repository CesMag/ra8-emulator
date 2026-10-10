//! Tests for src/board/image/pages.zig.
const std = @import("std");
const ra8 = @import("ra8");
const pages = ra8.board.image.pages;

const Set = pages.Set;
const Range = pages.Range;

test "a segment claims the pages it lands on, not the bytes" {
    var set = Set{};
    try set.add(0x0200_0040, 0x10);
    try std.testing.expectEqual(@as(usize, 1), set.items().len);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), set.items()[0].base);
    try std.testing.expectEqual(@as(u64, 0x0200_1000), set.items()[0].end);
    try std.testing.expectEqual(pages.page_bytes, set.items()[0].size());
}

test "a segment that spans a page boundary claims both pages" {
    var set = Set{};
    try set.add(0x0200_0FF0, 0x20);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), set.items()[0].base);
    try std.testing.expectEqual(@as(u64, 0x0200_2000), set.items()[0].end);
}

test "two segments sharing a page are one range, which is what a real image does" {
    // blink.elf: .text at 0x02000000 for 0x1F72, then .data at 0x02001F74.
    // Mapped separately the second asks for a page the first already holds.
    var set = Set{};
    try set.add(0x0200_0000, 0x1F72);
    try set.add(0x0200_1F74, 0x8D8);
    try std.testing.expectEqual(@as(usize, 1), set.items().len);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), set.items()[0].base);
    try std.testing.expectEqual(@as(u64, 0x0200_3000), set.items()[0].end);
}

test "ranges that only touch are joined, so no page is mapped twice" {
    var set = Set{};
    try set.add(0x0200_0000, 0x1000);
    try set.add(0x0200_1000, 0x1000);
    try std.testing.expectEqual(@as(usize, 1), set.items().len);
    try std.testing.expectEqual(@as(u64, 0x0200_2000), set.items()[0].end);
}

test "ranges a page apart stay apart" {
    var set = Set{};
    try set.add(0x0200_0000, 0x1000);
    try set.add(0x0200_2000, 0x1000);
    try std.testing.expectEqual(@as(usize, 2), set.items().len);
}

test "a claim bridging two ranges absorbs them both" {
    var set = Set{};
    try set.add(0x0200_0000, 0x1000);
    try set.add(0x0200_4000, 0x1000);
    try std.testing.expectEqual(@as(usize, 2), set.items().len);
    try set.add(0x0200_1000, 0x3000);
    try std.testing.expectEqual(@as(usize, 1), set.items().len);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), set.items()[0].base);
    try std.testing.expectEqual(@as(u64, 0x0200_5000), set.items()[0].end);
}

test "ranges come back in address order however they were claimed" {
    var set = Set{};
    try set.add(0x2E17_700, 0x224);
    try set.add(0x0200_0000, 0x10);
    try set.add(0x02C9_F040, 0x5C4);
    var previous: u32 = 0;
    for (set.items()) |range| {
        try std.testing.expect(range.base >= previous);
        previous = range.base;
    }
    try std.testing.expectEqual(@as(usize, 3), set.items().len);
}

test "a segment that reserves but carries nothing still claims its page" {
    var set = Set{};
    try set.add(0x2200_08D8, 0);
    try std.testing.expectEqual(@as(usize, 1), set.items().len);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), set.items()[0].base);
}

test "more disjoint ranges than the set holds is refused, not truncated" {
    var set = Set{};
    for (0..pages.capacity) |index| {
        try set.add(@intCast(index * 0x2000), 0x10);
    }
    try std.testing.expectEqual(pages.capacity, set.items().len);
    try std.testing.expectError(error.TooManyRanges, set.add(0x1000_0000, 0x10));
}

test "a claim that merges is not refused once the set is full" {
    var set = Set{};
    for (0..pages.capacity) |index| {
        try set.add(@intCast(index * 0x2000), 0x10);
    }
    try set.add(0x0000_0800, 0x10);
    try std.testing.expectEqual(pages.capacity, set.items().len);
}

test "a segment that runs where it loads claims its .bss too" {
    const bytes = @as([8]u8, @splat(0));
    const here = ra8.board.image.elf.Segment{ .vaddr = 0x2200_0000, .paddr = 0x2200_0000, .flags = 6, .bytes = &bytes, .memsz = 0x400 };
    try std.testing.expectEqual(@as(u64, 0x400), pages.loadSpan(here));
}

test "data copied out of MRAM claims only its file bytes at the load address" {
    const bytes = @as([0xD8]u8, @splat(0));
    // pagecache's .data: loads at the end of its text, runs in SRAM with
    // nearly 1 MiB of .bss that would run past the end of MRAM.
    const copied = ra8.board.image.elf.Segment{ .vaddr = 0x2200_0000, .paddr = 0x0202_65B8, .flags = 6, .bytes = &bytes, .memsz = 0xF_7B24 };
    try std.testing.expectEqual(@as(u64, 0xD8), pages.loadSpan(copied));
}
