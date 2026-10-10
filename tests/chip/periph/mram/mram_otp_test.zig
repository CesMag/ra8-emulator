//! Covers src/chip/periph/mram/mram_otp.zig: the legal Program window and the
//! one-time-programmable rule.
const std = @import("std");
const ra8 = @import("ra8");

const otp = ra8.chip.periph.mram_otp;

test "the window is HUM Table 59.15's range and nothing either side of it" {
    try std.testing.expect(otp.window.holds(otp.window.lo, 1));
    try std.testing.expect(otp.window.holds(otp.window.hi, 1));
    try std.testing.expect(!otp.window.holds(otp.window.lo - 1, 1));
    try std.testing.expect(!otp.window.holds(otp.window.hi + otp.window.program_bytes, 1));
    // The address ra8_flash_extra_mram_write used to target: not on this part.
    try std.testing.expect(!otp.window.holds(0x2700_0000, 16));
}

test "Program targets are the sparse Table 59.15 addresses" {
    const targets = [_]u32{
        0x02E0_7600,
        0x02E0_7610,
        0x02E0_7690,
        0x02E0_76A0,
        0x02E0_76F0,
        0x02E1_7700,
        0x02E1_7770,
        0x02E1_7780,
        0x02E1_77F0,
        0x02E1_7900,
        0x02E1_7910,
        0x02E1_7920,
        0x02E1_7930,
        0x02E1_7950,
        0x02E1_79F0,
    };
    for (targets) |target| {
        try std.testing.expect(otp.window.holds(target, otp.window.program_bytes));
    }
    try std.testing.expect(!otp.window.holds(0x02E0_7700, 16));
    try std.testing.expect(!otp.window.holds(0x02E0_9600, 16));
    try std.testing.expect(!otp.window.holds(0x02E1_7800, 16));
}

test "a Program command is one aligned 16-byte target unit" {
    try std.testing.expect(!otp.window.holds(otp.window.lo + 1, 1));
    try std.testing.expect(!otp.window.holds(otp.window.lo, otp.window.program_bytes + 1));
}

test "an unprogrammed cell reads erased and the store holds nothing" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try std.testing.expectEqual(otp.window.erased, cells.byte(otp.window.lo));
    try std.testing.expectEqual(@as(u32, 0), cells.live());
}

test "a program lands and is held" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try cells.program(otp.window.lo, &.{ 0x0F, 0x33 });
    try std.testing.expectEqual(@as(u8, 0x0F), cells.byte(otp.window.lo));
    try std.testing.expectEqual(@as(u8, 0x33), cells.byte(otp.window.lo + 1));
    try std.testing.expectEqual(@as(u32, 2), cells.live());
}

test "a program of the erased value holds no cell" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try cells.program(otp.window.lo, &.{0xFF});
    try std.testing.expectEqual(@as(u32, 0), cells.live());
}

test "clearing further bits is not a rewrite" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try cells.program(otp.window.lo, &.{0x3F});
    try std.testing.expect(!cells.rewrites(otp.window.lo, &.{0x0F}));
}

test "asking for a bit back is a rewrite" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try cells.program(otp.window.lo, &.{0x0F});
    try std.testing.expect(cells.rewrites(otp.window.lo, &.{0xFF}));
    try std.testing.expect(cells.rewrites(otp.window.lo, &.{0x1F}));
}

test "a rewrite is spotted anywhere in the payload" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try cells.program(otp.window.lo + 3, &.{0x00});
    try std.testing.expect(cells.rewrites(otp.window.lo, &.{ 0xFF, 0xFF, 0xFF, 0x01 }));
}

test "a program only clears bits" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try cells.program(otp.window.lo, &.{0x3C});
    try cells.program(otp.window.lo, &.{0x0F});
    try std.testing.expectEqual(@as(u8, 0x0C), cells.byte(otp.window.lo));
}

test "reset gives back a blank option memory" {
    var cells = otp.Cells.init(std.testing.allocator);
    defer cells.deinit();

    try cells.program(otp.window.lo, &.{0x00});
    cells.reset();
    try std.testing.expectEqual(otp.window.erased, cells.byte(otp.window.lo));
    try std.testing.expectEqual(@as(u32, 0), cells.live());
}
