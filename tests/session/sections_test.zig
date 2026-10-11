//! The section table: every allocated section of a real firmware image,
//! checked against `arm-none-eabi-objdump -h` of the same file.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const sections = ra8.session.sections;

const image_bytes = @embedFile("../fixtures/sections/fault_crashlog_hil.elf");

const Row = struct { name: []const u8, vma: u32, lma: u32, size: u32, kind: sections.Kind };

/// The rows objdump -h prints for the fixture, less the unallocated ones.
const expected = [_]Row{
    .{ .name = ".vectors", .vma = 0x0200_0000, .lma = 0x0200_0000, .size = 0x200, .kind = .read_only },
    .{ .name = ".text", .vma = 0x0200_0200, .lma = 0x0200_0200, .size = 0x22a0, .kind = .code },
    .{ .name = ".rodata", .vma = 0x0200_24a0, .lma = 0x0200_24a0, .size = 0xf64, .kind = .read_only },
    .{ .name = ".ARM.exidx", .vma = 0x0200_3404, .lma = 0x0200_3404, .size = 0x28, .kind = .read_only },
    .{ .name = ".option_setting_ofs0", .vma = 0x02c9_f040, .lma = 0x02c9_f040, .size = 4, .kind = .read_only },
    .{ .name = ".option_setting_ofs1", .vma = 0x02c9_f4c0, .lma = 0x02c9_f4c0, .size = 4, .kind = .read_only },
};

const tail = [_]Row{
    .{ .name = ".option_setting_otp_zhuk", .vma = 0x02e1_7920, .lma = 0x02e1_7920, .size = 4, .kind = .read_only },
    .{ .name = ".data", .vma = 0x2200_0000, .lma = 0x0200_342c, .size = 0x28, .kind = .initialised },
    .{ .name = ".bss", .vma = 0x2200_0028, .lma = 0x0200_3454, .size = 0xb30, .kind = .zero_fill },
    .{ .name = ".stack_canary", .vma = 0x2200_0b58, .lma = 0x0200_3458, .size = 0x20, .kind = .zero_fill },
    .{ .name = ".noinit", .vma = 0x220f_ff00, .lma = 0x220f_ff00, .size = 0x5c, .kind = .no_init },
};

fn expectRow(want: Row, got: sections.Section) !void {
    try std.testing.expectEqualStrings(want.name, got.name);
    try std.testing.expectEqual(want.vma, got.vma);
    try std.testing.expectEqual(want.lma, got.lma);
    try std.testing.expectEqual(want.size, got.size);
    try std.testing.expectEqual(want.kind, got.kind);
}

test "every allocated section is listed and nothing else" {
    const image = try elf.Image.init(image_bytes);
    // 37 headers: index 0, 26 allocated, .gnu.sgstubs (no ALLOC) and ten
    // debug, comment and attribute sections.
    try std.testing.expectEqual(@as(usize, 26), sections.count(image));
    try std.testing.expectEqual(@as(?sections.Section, null), sections.byName(image, ".debug_info"));
    try std.testing.expectEqual(@as(?sections.Section, null), sections.byName(image, ".gnu.sgstubs"));
}

test "the head and tail of the table match objdump" {
    const image = try elf.Image.init(image_bytes);
    var rows: [32]sections.Section = undefined;
    const n = sections.list(image, &rows);
    try std.testing.expectEqual(@as(usize, 26), n);
    for (expected, rows[0..expected.len]) |want, got| try expectRow(want, got);
    for (tail, rows[n - tail.len .. n]) |want, got| try expectRow(want, got);
}

test ".data runs in SRAM and is stored in MRAM, .bss and .noinit are not stored" {
    const image = try elf.Image.init(image_bytes);
    const data = sections.byName(image, ".data").?;
    try std.testing.expect(data.stored());
    try std.testing.expect(data.lma != data.vma);
    try std.testing.expect(!sections.byName(image, ".bss").?.stored());
    try std.testing.expect(!sections.byName(image, ".noinit").?.stored());
    try std.testing.expect(sections.byName(image, ".text").?.stored());
}

test "a short buffer keeps the first sections" {
    const image = try elf.Image.init(image_bytes);
    var rows: [2]sections.Section = undefined;
    try std.testing.expectEqual(@as(usize, 2), sections.list(image, &rows));
    try std.testing.expectEqualStrings(".text", rows[1].name);
}

test "a truncated image gives fewer sections, never a bad read" {
    // Cut before the section headers: the ELF header still parses, the
    // table is simply out of reach.
    const head = (try elf.Image.init(image_bytes)).header();
    const cut = try elf.Image.init(image_bytes[0..head.e_shoff]);
    try std.testing.expectEqual(@as(usize, 0), sections.count(cut));
    try std.testing.expectEqual(@as(?sections.Section, null), sections.byName(cut, ".text"));
}

test "a bad name table leaves names empty but keeps the sections" {
    var copy: [image_bytes.len]u8 = image_bytes.*;
    const head: *align(1) elf.Header = std.mem.bytesAsValue(elf.Header, copy[0..@sizeOf(elf.Header)]);
    head.e_shstrndx = 0xFFF0;
    const image = try elf.Image.init(&copy);
    try std.testing.expectEqual(@as(usize, 26), sections.count(image));
    var rows: [1]sections.Section = undefined;
    _ = sections.list(image, &rows);
    try std.testing.expectEqualStrings("", rows[0].name);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), rows[0].vma);
}
