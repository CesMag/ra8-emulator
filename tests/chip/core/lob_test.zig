//! Covers src/chip/core/lob.zig.
//!
//! Every encoding here was assembled by the pinned arm-none-eabi 13.3.rel1
//! for armv8.1-m.main and read back out of objdump, rather than derived from
//! the manual by hand: the branch distance packs its low bit at the top of
//! the field, which is exactly the sort of thing a careful reading gets
//! backwards and a real assembler does not.
const std = @import("std");
const ra8 = @import("ra8");
const lob = ra8.chip.core.lob;

test "DLS decodes with its source register" {
    // f040 e001  dls lr, r0
    const zero = lob.decode(0xF040, 0xE001).?;
    try std.testing.expectEqual(lob.Kind.dls, zero.kind);
    try std.testing.expectEqual(@as(u4, 0), zero.source);
    // f043 e001  dls lr, r3 ... f04e e001  dls lr, lr
    try std.testing.expectEqual(@as(u4, 3), lob.decode(0xF043, 0xE001).?.source);
    try std.testing.expectEqual(@as(u4, 14), lob.decode(0xF04E, 0xE001).?.source);
}

test "LE decodes its backward distance" {
    // The three at the top of the generated loop nest, at 0x02, 0x08 and
    // 0x0e, every one of them branching to 0x00.
    const cases = [_]struct { second: u16, bytes: u32 }{
        .{ .second = 0xC803, .bytes = 6 },
        .{ .second = 0xC007, .bytes = 12 },
        .{ .second = 0xC809, .bytes = 18 },
        .{ .second = 0xC00D, .bytes = 24 },
        .{ .second = 0xC80F, .bytes = 30 },
        .{ .second = 0xC025, .bytes = 72 },
    };
    for (cases) |case| {
        const decoded = lob.decode(0xF00F, case.second).?;
        try std.testing.expectEqual(lob.Kind.le, decoded.kind);
        try std.testing.expectEqual(case.bytes, decoded.offset);
    }
}

test "WLS decodes its source register and its forward distance" {
    // f042 c007  wls lr, r2, +12   and   f041 c801  wls lr, r1, +2
    const twelve = lob.decode(0xF042, 0xC007).?;
    try std.testing.expectEqual(lob.Kind.wls, twelve.kind);
    try std.testing.expectEqual(@as(u4, 2), twelve.source);
    try std.testing.expectEqual(@as(u32, 12), twelve.offset);

    const two = lob.decode(0xF041, 0xC801).?;
    try std.testing.expectEqual(@as(u4, 1), two.source);
    try std.testing.expectEqual(@as(u32, 2), two.offset);
}

test "WLS and LE require hw2 bit zero" {
    try std.testing.expect(lob.decode(0xF040, 0xC004) == null);
    try std.testing.expect(lob.decode(0xF00F, 0xC004) == null);
}

test "anything else stays undecoded, so it stays a fault" {
    // LETP: an MVE tail-predicated loop end. Refused on purpose, because
    // counting its iterations right would still run the body wrong.
    try std.testing.expect(lob.decode(lob.encoding.letp_first, 0xC007) == null);
    // A plain 32-bit data-processing encoding, and a 16-bit pair that
    // happens to sit where the second halfword is read.
    try std.testing.expect(lob.decode(0xF04F, 0x0300) == null);
    try std.testing.expect(lob.decode(0xBF00, 0xBF00) == null);
    // The DLS second halfword under a first halfword that is not the setup.
    try std.testing.expect(lob.decode(0xF00F, 0xE001) == null);
}

test "DLS loads the counter and falls through" {
    const taken = lob.step(.{ .kind = .dls, .source = 0 }, 0x2200_0100, 7, 0xDEAD);
    try std.testing.expectEqual(@as(u32, 0x2200_0104), taken.next_pc);
    try std.testing.expectEqual(@as(?u32, 7), taken.lr);
}

test "WLS skips the body on a zero trip count" {
    const wls = lob.Instruction{ .kind = .wls, .source = 1, .offset = 12 };
    const skipped = lob.step(wls, 0x2200_0100, 0, 0xDEAD);
    try std.testing.expectEqual(@as(u32, 0x2200_0110), skipped.next_pc);
    // The counter is left alone: WLS that skips never wrote LR.
    try std.testing.expectEqual(@as(?u32, null), skipped.lr);

    const entered = lob.step(wls, 0x2200_0100, 3, 0xDEAD);
    try std.testing.expectEqual(@as(u32, 0x2200_0104), entered.next_pc);
    try std.testing.expectEqual(@as(?u32, 3), entered.lr);
}

test "LE counts down and falls out on the iteration that empties the counter" {
    const le = lob.Instruction{ .kind = .le, .offset = 8 };
    const again = lob.step(le, 0x2200_0100, 0, 3);
    try std.testing.expectEqual(@as(u32, 0x2200_00FC), again.next_pc);
    try std.testing.expectEqual(@as(?u32, 2), again.lr);

    // The decrement happens first, so a counter of one does NOT branch: the
    // body it would have gone back for has already run. Branching here is
    // the off-by-one that makes a copy loop write one element too many.
    const last = lob.step(le, 0x2200_0100, 0, 1);
    try std.testing.expectEqual(@as(u32, 0x2200_0104), last.next_pc);
    try std.testing.expectEqual(@as(?u32, 0), last.lr);

    // Zero on entry falls through untouched rather than wrapping.
    const done = lob.step(le, 0x2200_0100, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x2200_0104), done.next_pc);
    try std.testing.expectEqual(@as(?u32, null), done.lr);
}

test "DLS LR, Rn runs the body exactly Rn times" {
    // dls lr, r0 / a two-halfword body / le back over it. This is the shape
    // GCC emits for a counted copy, and the count has to land exactly.
    const dls = lob.Instruction{ .kind = .dls, .source = 0 };
    const le = lob.Instruction{ .kind = .le, .offset = 6 };
    const top: u32 = 0x2200_0100;
    const end = top + lob.encoding.width + 2;

    for ([_]u32{ 1, 2, 4, 17 }) |count| {
        var lr = lob.step(dls, top, count, 0).lr.?;
        var body: u32 = 1;
        while (body < 64) {
            const taken = lob.step(le, end, 0, lr);
            if (taken.lr) |value| lr = value;
            if (taken.next_pc == end + lob.encoding.width) break;
            body += 1;
        }
        try std.testing.expectEqual(count, body);
        try std.testing.expectEqual(@as(u32, 0), lr);
    }
}

test "the counter is reported only when the hook was used" {
    var loops = lob.Loops{};
    try std.testing.expect(loops.quiet());
    loops.stepped += 1;
    try std.testing.expect(!loops.quiet());
}
