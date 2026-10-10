const std = @import("std");
const ra8 = @import("ra8");
const tz = ra8.chip.core.tz;

test "a BLXNS decodes to the register it branches through" {
    // BLXNS r2 is 0x4794, the one the RA8D2 secure boot issues.
    try std.testing.expectEqual(@as(?u4, 2), tz.decode(0x4794));
}

test "every register a BLXNS can name decodes back out of the encoding" {
    var which: u4 = 0;
    while (true) {
        const halfword: u16 = 0x4780 | (@as(u16, which) << 3) | 0x04;
        try std.testing.expectEqual(@as(?u4, which), tz.decode(halfword));
        if (which == 15) break;
        which += 1;
    }
}

test "a plain BLX is not a BLXNS" {
    // BLX r2 is 0x4790: the same family, without the bit that makes it the
    // Non-Secure call. Taking it for one would branch a Secure call into the
    // seam and stop the chunk for nothing.
    try std.testing.expectEqual(@as(?u4, null), tz.decode(0x4790));
}

test "an unrelated halfword is not a BLXNS" {
    try std.testing.expectEqual(@as(?u4, null), tz.decode(0xB580));
    try std.testing.expectEqual(@as(?u4, null), tz.decode(0x0000));
    try std.testing.expectEqual(@as(?u4, null), tz.decode(0xE002));
}

test "the first BLXNS in a stretch of code is the one found" {
    // push {r7, lr}; blxns r2; movs r3, #0; blxns r1
    const code = [_]u8{ 0x80, 0xB5, 0x94, 0x47, 0x00, 0x23, 0x8C, 0x47 };
    try std.testing.expectEqual(@as(?u32, 2), tz.findBlxns(&code));
}

test "code holding no BLXNS finds none" {
    const code = [_]u8{ 0x80, 0xB5, 0x86, 0xB0, 0x00, 0xAF, 0x78, 0x60 };
    try std.testing.expectEqual(@as(?u32, null), tz.findBlxns(&code));
}

test "a literal pool the secure boot carries holds no BLXNS" {
    // The words at the end of ra8_tz_secure_boot_jump_ns: the VTOR_NS
    // address, the log anchor and the step counter. A halfword scan walks
    // straight through them, which is what makes scanning the whole symbol
    // safe.
    const code = [_]u8{
        0x04, 0x00, 0x00, 0x22, 0xe0, 0x1c, 0x00, 0x02,
        0xf0, 0x1c, 0x00, 0x02, 0x0c, 0x1d, 0x00, 0x02,
        0x24, 0x1d, 0x00, 0x02, 0x08, 0xed, 0x02, 0xe0,
        0xf8, 0x04, 0x00, 0x22,
    };
    try std.testing.expectEqual(@as(?u32, null), tz.findBlxns(&code));
}

test "an odd tail byte is not read past" {
    const code = [_]u8{0x94};
    try std.testing.expectEqual(@as(?u32, null), tz.findBlxns(&code));
    try std.testing.expectEqual(@as(?u32, null), tz.findBlxns(&.{}));
}

test "entering the world puts the Thumb bit back on the program counter" {
    // The firmware clears bit 0 before the BLXNS, because a real one faults
    // on a target that still carries it. The program counter reads that same bit as
    // Thumb state, so the branch has to put it back.
    const entry = tz.enter(0x0208_00F0, 0x2219_0000, 0x0200_179E);
    try std.testing.expectEqual(@as(u32, 0x0208_00F1), entry.pc);
    try std.testing.expectEqual(@as(?u32, 0x2219_0000), entry.sp);
    try std.testing.expectEqual(@as(u32, 0x0200_179F), entry.lr);
}

test "a target that still carries bit 0 is branched to cleanly" {
    const entry = tz.enter(0x0208_00F1, null, 0x0200_179E);
    try std.testing.expectEqual(@as(u32, 0x0208_00F1), entry.pc);
    try std.testing.expectEqual(@as(?u32, null), entry.sp);
}

test "the return address is the instruction after the BLXNS" {
    // A real BLXNS leaves FNC_RETURN in LR and the core unstacks the Secure
    // frame from it. In one flat space the same effect is the address after
    // the call, so a Non-Secure function that returns lands where the
    // architecture would have put it rather than in its caller's caller.
    const entry = tz.enter(0x0208_00F0, 0x2219_0000, 0x0200_179C +% tz.encoding.width);
    try std.testing.expectEqual(@as(u32, 0x0200_179F), entry.lr);
}

test "an image with no secure boot in it says nothing" {
    const worlds = tz.Worlds{};
    try std.testing.expect(worlds.quiet());
    try std.testing.expect(!worlds.entered());
}

test "a seam that was armed and never reached is not quiet" {
    const worlds = tz.Worlds{ .armed_at = 0x0200_179C };
    try std.testing.expect(!worlds.quiet());
    try std.testing.expect(!worlds.entered());
}

test "recording a switch keeps where it went and what it ran on" {
    var worlds = tz.Worlds{ .armed_at = 0x0200_179C };
    worlds.record(tz.enter(0x0208_00F0, 0x2219_0000, 0x0200_179E));
    try std.testing.expect(worlds.entered());
    try std.testing.expectEqual(@as(usize, 1), worlds.switched);
    // Reported without the Thumb bit: the address of the instruction, not
    // the value a branch was given.
    try std.testing.expectEqual(@as(u32, 0x0208_00F0), worlds.entered_at);
    try std.testing.expectEqual(@as(u32, 0x2219_0000), worlds.stack);
}

test "a switch that kept the Secure stack records no stack of its own" {
    var worlds = tz.Worlds{ .armed_at = 0x0200_179C };
    worlds.record(tz.enter(0x0208_00F0, null, 0x0200_179E));
    try std.testing.expect(worlds.entered());
    try std.testing.expectEqual(@as(u32, 0), worlds.stack);
}
