//! Covers src/chip/core/csel.zig.
//!
//! The Zig core's executor is covered in tests/chip/core/cpu/ops/csel_test.zig.
//! What is worth checking here is the decode and the four tails, against the
//! encodings arm-none-eabi-as 13.3.rel1 produced for armv8.1-m.main.
const std = @import("std");
const ra8 = @import("ra8");
const csel = ra8.chip.core.csel;

const z_set: u32 = csel.flag.zero;
const nothing_set: u32 = 0;

test "csel r0, r1, r2, eq decodes to a plain select" {
    const found = csel.decode(0xEA51, 0x8002).?;
    try std.testing.expectEqual(csel.Kind.sel, found.kind);
    try std.testing.expectEqual(@as(u4, 1), found.then_source);
    try std.testing.expectEqual(@as(u4, 2), found.else_source);
    try std.testing.expectEqual(@as(u4, 0), found.destination);
    try std.testing.expectEqual(@as(u4, 0), found.condition);
}

test "the four kinds are read out of the top nibble of the second halfword" {
    try std.testing.expectEqual(csel.Kind.sel, csel.decode(0xEA51, 0x8002).?.kind);
    try std.testing.expectEqual(csel.Kind.inc, csel.decode(0xEA51, 0x9002).?.kind);
    try std.testing.expectEqual(csel.Kind.inv, csel.decode(0xEA51, 0xA002).?.kind);
    try std.testing.expectEqual(csel.Kind.neg, csel.decode(0xEA51, 0xB002).?.kind);
}

test "high registers land in the right fields" {
    // ea5b 8a6c: csel sl, fp, ip, vs
    const found = csel.decode(0xEA5B, 0x8A6C).?;
    try std.testing.expectEqual(@as(u4, 11), found.then_source);
    try std.testing.expectEqual(@as(u4, 12), found.else_source);
    try std.testing.expectEqual(@as(u4, 10), found.destination);
    try std.testing.expectEqual(@as(u4, 6), found.condition);
}

test "anything that is not one of the four is left alone" {
    // A low-overhead loop setup, which belongs to the other hook.
    try std.testing.expect(csel.decode(0xF040, 0xE001) == null);
    // The right first halfword but a kind field outside 8..B.
    try std.testing.expect(csel.decode(0xEA51, 0x7002) == null);
    try std.testing.expect(csel.decode(0xEA51, 0xC002) == null);
}

test "UNPREDICTABLE encodings are refused rather than invented" {
    // ea50 90e0: condition AL, which objdump itself calls undefined.
    try std.testing.expect(csel.decode(0xEA50, 0x90E0) == null);
    // Condition 0b1111.
    try std.testing.expect(csel.decode(0xEA51, 0x80F2) == null);
    // SP as the destination, then as each source.
    try std.testing.expect(csel.decode(0xEA51, 0x8D02) == null);
    try std.testing.expect(csel.decode(0xEA5D, 0x8002) == null);
    try std.testing.expect(csel.decode(0xEA51, 0x800D) == null);
    // The zero register as the destination.
    try std.testing.expect(csel.decode(0xEA51, 0x8F02) == null);
}

test "the condition holding takes the then-source whichever kind it is" {
    for ([_]u16{ 0x8002, 0x9002, 0xA002, 0xB002 }) |second| {
        const found = csel.decode(0xEA51, second).?;
        try std.testing.expectEqual(@as(u32, 7), csel.select(found, z_set, 7, 100));
    }
}

test "the condition failing puts the else-source through the tail" {
    const sel = csel.decode(0xEA51, 0x8002).?;
    const inc = csel.decode(0xEA51, 0x9002).?;
    const inv = csel.decode(0xEA51, 0xA002).?;
    const neg = csel.decode(0xEA51, 0xB002).?;
    try std.testing.expectEqual(@as(u32, 100), csel.select(sel, nothing_set, 7, 100));
    try std.testing.expectEqual(@as(u32, 101), csel.select(inc, nothing_set, 7, 100));
    try std.testing.expectEqual(~@as(u32, 100), csel.select(inv, nothing_set, 7, 100));
    try std.testing.expectEqual(0 -% @as(u32, 100), csel.select(neg, nothing_set, 7, 100));
}

test "the tails wrap rather than trap at the edges" {
    const inc = csel.decode(0xEA51, 0x9002).?;
    const neg = csel.decode(0xEA51, 0xB002).?;
    try std.testing.expectEqual(@as(u32, 0), csel.select(inc, nothing_set, 0, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u32, 0), csel.select(neg, nothing_set, 0, 0));
}

test "cset is csinc against the zero register, and reads as one" {
    // ea5f 901f: cset r0, eq. Both sources are the zero register and the
    // encoded condition is ne, so eq gives 1 and ne gives 0.
    const found = csel.decode(0xEA5F, 0x901F).?;
    try std.testing.expectEqual(csel.Kind.inc, found.kind);
    try std.testing.expectEqual(csel.encoding.zero_register, found.then_source);
    try std.testing.expectEqual(csel.encoding.zero_register, found.else_source);
    try std.testing.expectEqual(@as(u4, 1), found.condition);
    try std.testing.expectEqual(@as(u32, 1), csel.select(found, z_set, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), csel.select(found, nothing_set, 0, 0));
}

test "csetm gives an all-ones mask through the invert tail" {
    // ea5f a2af: csetm r2, lt, encoded as csinv r2, zr, zr, ge.
    const found = csel.decode(0xEA5F, 0xA2AF).?;
    try std.testing.expectEqual(csel.Kind.inv, found.kind);
    // N set and V clear is lt, so ge fails and the mask lands.
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), csel.select(found, csel.flag.negative, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), csel.select(found, nothing_set, 0, 0));
}

test "every condition code reads the flags the ordinary way" {
    const n = csel.flag.negative;
    const z = csel.flag.zero;
    const c = csel.flag.carry;
    const v = csel.flag.overflow;
    try std.testing.expect(csel.passes(0, z) and !csel.passes(0, 0));
    try std.testing.expect(csel.passes(1, 0) and !csel.passes(1, z));
    try std.testing.expect(csel.passes(2, c) and !csel.passes(2, 0));
    try std.testing.expect(csel.passes(3, 0) and !csel.passes(3, c));
    try std.testing.expect(csel.passes(4, n) and !csel.passes(4, 0));
    try std.testing.expect(csel.passes(5, 0) and !csel.passes(5, n));
    try std.testing.expect(csel.passes(6, v) and !csel.passes(6, 0));
    try std.testing.expect(csel.passes(7, 0) and !csel.passes(7, v));
    // hi is C and not Z; ls is its negation.
    try std.testing.expect(csel.passes(8, c) and !csel.passes(8, c | z));
    try std.testing.expect(csel.passes(9, c | z) and !csel.passes(9, c));
    // ge is N == V; lt is N != V.
    try std.testing.expect(csel.passes(10, n | v) and !csel.passes(10, n));
    try std.testing.expect(csel.passes(11, n) and !csel.passes(11, n | v));
    // gt is not Z and N == V; le is its negation.
    try std.testing.expect(csel.passes(12, 0) and !csel.passes(12, z));
    try std.testing.expect(csel.passes(13, z) and !csel.passes(13, 0));
}

test "the counter stays quiet until the hook needs it" {
    var selects = csel.Selects{};
    try std.testing.expect(selects.quiet());
    selects.stepped += 1;
    try std.testing.expect(!selects.quiet());
}
