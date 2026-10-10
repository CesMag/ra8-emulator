//! Tests for src/chip/periph/doc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const periph = ra8.chip.periph.registry;
const mod = ra8.chip.periph.doc;

const Doc = mod.Doc;
const Mode = mod.Mode;
const dcsel_shift = ra8.chip.periph.doc_compare.field.shift;
const dobw_32 = mod.dobw_32;
const dopcf = mod.dopcf;
const off_docr = mod.off_docr;
const off_dodir = mod.off_dodir;
const off_dodsr0 = mod.off_dodsr0;
const off_dodsr1 = mod.off_dodsr1;
const off_doscr = mod.off_doscr;
const off_dosr = mod.off_dosr;
const regAddress = mod.regAddress;

const docr_add_32: u32 = @backingInt(Mode.add) | dobw_32;

const docr_sub_32: u32 = @backingInt(Mode.subtract) | dobw_32;
test "an eight-entry add chain leaves the hardware sum in DODSR0" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 0);

    var expected: u32 = 0;
    const entries = [_]u32{ 1, 2, 3, 5, 8, 13, 21, 34 };
    for (entries) |entry| {
        unit.write(regAddress(off_dodir), 4, entry);
        expected += entry;
    }
    try std.testing.expectEqual(expected, unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dosr), 1));
    try std.testing.expectEqual(@as(u32, 8), unit.ops);
}

test "a seeded reference is the first operand, not a cleared accumulator" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 1000);
    unit.write(regAddress(off_dodir), 4, 24);
    try std.testing.expectEqual(@as(u32, 1024), unit.read(regAddress(off_dodsr0), 4));
}

test "a 16-bit add wraps at the width and latches DOPCF" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, @backingInt(Mode.add)); // DOBW clear
    unit.write(regAddress(off_dodsr0), 4, 0xFFF0);
    unit.write(regAddress(off_dodir), 4, 0x0020);
    try std.testing.expectEqual(@as(u32, 0x0010), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, dopcf), unit.read(regAddress(off_dosr), 1));
}

test "a 32-bit add carries out of bit 31, which the C tree could not see" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 0xFFFF_FFF0);
    unit.write(regAddress(off_dodir), 4, 0x20);
    try std.testing.expectEqual(@as(u32, 0x10), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expect(unit.flag);
}

test "DOPCF is sticky until DOSCR clears it" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, @backingInt(Mode.add));
    unit.write(regAddress(off_dodsr0), 4, 0xFFFF);
    unit.write(regAddress(off_dodir), 4, 1); // carries
    try std.testing.expect(unit.flag);

    unit.write(regAddress(off_dodir), 4, 1); // does not carry
    try std.testing.expect(unit.flag); // still latched

    unit.write(regAddress(off_dosr), 1, 0); // read-only, no effect
    try std.testing.expect(unit.flag);

    unit.write(regAddress(off_doscr), 1, dopcf);
    try std.testing.expect(!unit.flag);
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dosr), 1));
}

test "subtract borrows below zero and masks to the width" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_sub_32);
    unit.write(regAddress(off_dodsr0), 4, 100);
    unit.write(regAddress(off_dodir), 4, 40);
    try std.testing.expectEqual(@as(u32, 60), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expect(!unit.flag);

    unit.write(regAddress(off_dodir), 4, 100); // 60 - 100 borrows
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFD8), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expect(unit.flag);
}

test "compare leaves the accumulator alone and only moves the flag" {
    var match = Doc.init();
    match.write(regAddress(off_docr), 1, @backingInt(Mode.compare) | (1 << dcsel_shift) | dobw_32);
    match.write(regAddress(off_dodsr0), 4, 0xABCD_1234);
    match.write(regAddress(off_dodir), 4, 0xABCD_1234);
    try std.testing.expect(match.flag);
    try std.testing.expectEqual(@as(u32, 0xABCD_1234), match.read(regAddress(off_dodsr0), 4));

    var differ = Doc.init();
    differ.write(regAddress(off_docr), 1, @backingInt(Mode.compare) | dobw_32);
    differ.write(regAddress(off_dodsr0), 4, 7);
    differ.write(regAddress(off_dodir), 4, 7);
    try std.testing.expect(!differ.flag); // mismatch relation, operands match
    differ.write(regAddress(off_dodir), 4, 8);
    try std.testing.expect(differ.flag);
}

test "the reference and threshold take narrow writes and read back through aliases" {
    var unit = Doc.init();
    unit.write(regAddress(off_dodsr0), 4, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xDD), unit.read(regAddress(off_dodsr0), 1));
    try std.testing.expectEqual(@as(u32, 0xAABB), unit.read(regAddress(off_dodsr0 + 2), 2));
    unit.write(regAddress(off_dodsr0 + 2), 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234_CCDD), unit.read(regAddress(off_dodsr0), 4));

    unit.write(regAddress(off_dodsr1), 4, 0x0000_FFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFF), unit.read(regAddress(off_dodsr1), 4));
    try std.testing.expect(unit.quiet());
}

test "DODIR and DOSCR read zero rather than a stand-in value" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodir), 4, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dodir), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_doscr), 1));
    try std.testing.expectEqual(@as(u32, docr_add_32), unit.read(regAddress(off_docr), 1));
    try std.testing.expectEqual(Mode.add, unit.mode());
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.widthMask());
}

test "the unit answers on the bus, in both windows" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = Doc.init();
    try bus.add(unit.block());

    bus.write(regAddress(off_docr), 1, docr_add_32);
    bus.write(regAddress(off_dodsr0), 4, 0);
    bus.write(periph.ns_base + (regAddress(off_dodir) - periph.base), 4, 0x2000);
    bus.write(regAddress(off_dodir), 4, 0x0024);
    try std.testing.expectEqual(@as(u32, 0x2024), bus.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(usize, 0), bus.unmodelledAddresses());
}

test "a byte store at DODIR is not an operand, it is a refusal" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 0x1000);
    unit.write(regAddress(off_dodir), 1, 0x24);
    // Nothing ran: the accumulator is untouched and the store is counted.
    try std.testing.expectEqual(@as(u32, 0x1000), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.ops);
    try std.testing.expectEqual(@as(u32, 1), unit.refused());
}

test "a halfword store above lane 0 is counted instead of vanishing" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 0x1000);
    unit.write(regAddress(off_dodir) + 2, 2, 0xBEEF);
    try std.testing.expectEqual(@as(u32, 0x1000), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.ops);
    try std.testing.expectEqual(@as(u32, 1), unit.refused());
}

test "a 32-bit operand put in as two halfwords runs nothing at all" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 0);
    unit.write(regAddress(off_dodir), 2, 0xDEAD);
    unit.write(regAddress(off_dodir) + 2, 2, 0xBEEF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.ops);
    try std.testing.expectEqual(@as(u32, 2), unit.refused());
}

test "a halfword store still carries the 16-bit operand ra8_doc.c writes" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, @backingInt(Mode.add)); // DOBW clear
    unit.write(regAddress(off_dodsr0), 4, 0x0100);
    unit.write(regAddress(off_dodir), 2, 0x0024);
    try std.testing.expectEqual(@as(u32, 0x0124), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.ops);
    try std.testing.expectEqual(@as(u32, 0), unit.refused());
}

test "a refused store keeps a unit out of quiet, so the run reports it" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    try std.testing.expect(unit.quiet());
    unit.write(regAddress(off_dodir) + 1, 1, 0x24);
    try std.testing.expect(!unit.quiet());
    try std.testing.expectEqual(@as(u32, 1), unit.refused());
}

test "a word store carries either width, which is the deinit zeroing" {
    var unit = Doc.init();
    unit.write(regAddress(off_docr), 1, docr_add_32);
    unit.write(regAddress(off_dodsr0), 4, 7);
    unit.write(regAddress(off_dodir), 4, 0);
    try std.testing.expectEqual(@as(u32, 7), unit.read(regAddress(off_dodsr0), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.ops);
    try std.testing.expectEqual(@as(u32, 0), unit.refused());
}
