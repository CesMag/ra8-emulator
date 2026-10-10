//! The DCSEL relations, including the two that read DODSR1 as an upper bound.
const std = @import("std");
const ra8 = @import("ra8");
const compare = ra8.chip.periph.doc_compare;
const doc = ra8.chip.periph.doc;

fn docr(dcsel: u8) u8 {
    return dcsel << compare.field.shift;
}

test "DCSEL is read out of DOCR bits 6:4, ignoring the mode and width bits" {
    // OMS=00, DOBW clear, DCSEL=4.
    try std.testing.expectEqual(compare.Relation.inside, compare.Relation.of(0x40));
    // The same relation with DOBW set alongside it.
    try std.testing.expectEqual(compare.Relation.inside, compare.Relation.of(0x48));
    try std.testing.expectEqual(compare.Relation.outside, compare.Relation.of(0x50));
    try std.testing.expectEqual(compare.Relation.mismatch, compare.Relation.of(0x00));
}

test "the four single-reference relations weigh DODIR against DODSR0" {
    try std.testing.expect(compare.hit(.mismatch, 7, 9, 0));
    try std.testing.expect(!compare.hit(.mismatch, 9, 9, 0));
    try std.testing.expect(compare.hit(.match, 9, 9, 0));
    try std.testing.expect(!compare.hit(.match, 7, 9, 0));
    // lower: DODSR0 > DODIR.
    try std.testing.expect(compare.hit(.lower, 7, 9, 0));
    try std.testing.expect(!compare.hit(.lower, 11, 9, 0));
    // upper: DODSR0 < DODIR.
    try std.testing.expect(compare.hit(.upper, 11, 9, 0));
    try std.testing.expect(!compare.hit(.upper, 7, 9, 0));
}

test "inside window is strict at both bounds" {
    try std.testing.expect(compare.hit(.inside, 0x1000, 0x0800, 0x1800));
    try std.testing.expect(!compare.hit(.inside, 0x0400, 0x0800, 0x1800));
    try std.testing.expect(!compare.hit(.inside, 0x1C00, 0x0800, 0x1800));
    // Boundary values satisfy neither window condition.
    try std.testing.expect(!compare.hit(.inside, 0x0800, 0x0800, 0x1800));
    try std.testing.expect(!compare.hit(.inside, 0x1800, 0x0800, 0x1800));
}

test "outside window is the strict complement of inside, bounds included" {
    try std.testing.expect(compare.hit(.outside, 0x0400, 0x0800, 0x1800));
    try std.testing.expect(compare.hit(.outside, 0x1C00, 0x0800, 0x1800));
    try std.testing.expect(!compare.hit(.outside, 0x1000, 0x0800, 0x1800));
    // A bound is in neither window, so it is outside-false as well.
    try std.testing.expect(!compare.hit(.outside, 0x0800, 0x0800, 0x1800));
    try std.testing.expect(!compare.hit(.outside, 0x1800, 0x0800, 0x1800));
}

test "only the window relations read DODSR1" {
    try std.testing.expect(compare.Relation.inside.windowed());
    try std.testing.expect(compare.Relation.outside.windowed());
    try std.testing.expect(!compare.Relation.match.windowed());
    try std.testing.expect(!compare.Relation.upper.windowed());
    try std.testing.expect(!compare.Relation.mismatch.windowed());
}

test "the reserved encodings answer as the reset relation and say so" {
    const reserved: compare.Relation = @fromBackingInt(@intCast(6));
    try std.testing.expect(compare.hit(reserved, 7, 9, 0));
    try std.testing.expect(!compare.hit(reserved, 9, 9, 0));
    try std.testing.expect(!reserved.windowed());
    try std.testing.expectEqualStrings("reserved condition", reserved.name());
}

test "an inside-window compare latches DOPCF only for a value between the bounds" {
    var unit = doc.Doc.init();
    unit.write(doc.win_base + doc.off_docr, 1, docr(4));
    unit.write(doc.win_base + doc.off_dodsr0, 2, 0x0800);
    unit.write(doc.win_base + doc.off_dodsr1, 2, 0x1800);

    unit.write(doc.win_base + doc.off_dodir, 2, 0x0400);
    try std.testing.expectEqual(@as(u32, 0), unit.read(doc.win_base + doc.off_dosr, 1));

    unit.write(doc.win_base + doc.off_dodir, 2, 0x1000);
    try std.testing.expectEqual(@as(u32, doc.dopcf), unit.read(doc.win_base + doc.off_dosr, 1));

    // The accumulator is untouched by a comparison, window or not.
    try std.testing.expectEqual(@as(u32, 0x0800), unit.read(doc.win_base + doc.off_dodsr0, 4));
}

test "an outside-window compare answers the other way round on the same bounds" {
    var unit = doc.Doc.init();
    unit.write(doc.win_base + doc.off_docr, 1, docr(5));
    unit.write(doc.win_base + doc.off_dodsr0, 2, 0x0800);
    unit.write(doc.win_base + doc.off_dodsr1, 2, 0x1800);

    unit.write(doc.win_base + doc.off_dodir, 2, 0x1000);
    try std.testing.expectEqual(@as(u32, 0), unit.read(doc.win_base + doc.off_dosr, 1));

    unit.write(doc.win_base + doc.off_dodir, 2, 0x1C00);
    try std.testing.expectEqual(@as(u32, doc.dopcf), unit.read(doc.win_base + doc.off_dosr, 1));
}

test "a window compare no longer latches the way a bare mismatch would" {
    // The value is not equal to DODSR0, which is what used to set the flag for
    // every encoding but match, and it is inside the window, so outside must
    // stay clear.
    var unit = doc.Doc.init();
    unit.write(doc.win_base + doc.off_docr, 1, docr(5));
    unit.write(doc.win_base + doc.off_dodsr0, 2, 0x0800);
    unit.write(doc.win_base + doc.off_dodsr1, 2, 0x1800);
    unit.write(doc.win_base + doc.off_dodir, 2, 0x0C00);
    try std.testing.expectEqual(@as(u32, 0), unit.read(doc.win_base + doc.off_dosr, 1));
}

test "windowed compares are counted and the rest are not" {
    var unit = doc.Doc.init();
    unit.write(doc.win_base + doc.off_docr, 1, docr(1));
    unit.write(doc.win_base + doc.off_dodir, 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 0), unit.windows);

    unit.write(doc.win_base + doc.off_docr, 1, docr(4));
    unit.write(doc.win_base + doc.off_dodsr1, 2, 0x1800);
    unit.write(doc.win_base + doc.off_dodir, 2, 0x0001);
    unit.write(doc.win_base + doc.off_dodir, 2, 0x0002);
    try std.testing.expectEqual(@as(u32, 2), unit.windows);
    try std.testing.expectEqual(compare.Relation.inside, unit.relation());
}

test "a 16-bit window ignores anything DODSR1 carries above the width" {
    var unit = doc.Doc.init();
    unit.write(doc.win_base + doc.off_docr, 1, docr(4));
    unit.write(doc.win_base + doc.off_dodsr0, 4, 0x0000_0800);
    unit.write(doc.win_base + doc.off_dodsr1, 4, 0xDEAD_1800);
    unit.write(doc.win_base + doc.off_dodir, 2, 0x1000);
    try std.testing.expectEqual(@as(u32, doc.dopcf), unit.read(doc.win_base + doc.off_dosr, 1));
}
