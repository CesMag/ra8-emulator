const std = @import("std");
const ra8 = @import("ra8");
const div = ra8.chip.periph.pll.div;

test "PLIDIV is ratio minus one for the three the part supports" {
    try std.testing.expectEqual(@as(u8, 1), div.inputRatio(0).?);
    try std.testing.expectEqual(@as(u8, 2), div.inputRatio(1).?);
    try std.testing.expectEqual(@as(u8, 3), div.inputRatio(2).?);
    try std.testing.expect(div.inputRatio(3) == null);
}

test "PLODIV code 0 is prohibited rather than divide by one" {
    try std.testing.expect(div.outputRatio(0) == null);
    try std.testing.expectEqual(@as(u8, 2), div.outputRatio(1).?);
    try std.testing.expectEqual(@as(u8, 6), div.outputRatio(5).?);
    try std.testing.expectEqual(@as(u8, 8), div.outputRatio(7).?);
    try std.testing.expectEqual(@as(u8, 9), div.outputRatio(8).?);
    try std.testing.expectEqual(@as(u8, 16), div.outputRatio(15).?);
}

test "the codes between the discrete ratios are undefined" {
    for ([_]u4{ 6, 9, 10, 11, 12, 13, 14 }) |code| {
        try std.testing.expect(div.outputRatio(code) == null);
    }
}

test "the quickstart PLLCCR decodes to main in, divide by three, times 250" {
    const word: u32 = 0xFA02;
    try std.testing.expectEqual(div.Source.main, div.sourceOf(word));
    try std.testing.expectEqual(@as(u8, 3), div.inputRatio(div.inputCodeOf(word)).?);
    const mul = div.multiplierOf(word);
    try std.testing.expectEqual(@as(u16, 250), mul.whole());
    try std.testing.expectEqual(@as(u8, 0), mul.hundredths());
}

test "a quarter step shows up as hundredths rather than a rounded whole" {
    const mul = div.Multiplier{ .quarters = 250 * 4 + 3 };
    try std.testing.expectEqual(@as(u16, 250), mul.whole());
    try std.testing.expectEqual(@as(u8, 75), mul.hundredths());
}

test "PLSRCSEL bit 4 picks HOCO" {
    try std.testing.expectEqual(div.Source.hoco, div.sourceOf(0x10));
    try std.testing.expectEqualStrings("HOCO", div.Source.hoco.name());
    try std.testing.expectEqualStrings("main", div.Source.main.name());
}

test "the quickstart PLLCCR2 decodes to P/2 Q/6 R/5" {
    const codes = div.outputCodesOf(0x451);
    try std.testing.expectEqual(@as(u4, 1), codes[0]);
    try std.testing.expectEqual(@as(u4, 5), codes[1]);
    try std.testing.expectEqual(@as(u4, 4), codes[2]);
    try std.testing.expect(div.outputsAllowed(0x451));
}

test "one prohibited field is enough to disallow the whole word" {
    try std.testing.expect(!div.outputsAllowed(0x450));
    try std.testing.expect(!div.outputsAllowed(0x401));
    try std.testing.expect(!div.outputsAllowed(0x051));
    try std.testing.expect(!div.outputsAllowed(0x000));
}
