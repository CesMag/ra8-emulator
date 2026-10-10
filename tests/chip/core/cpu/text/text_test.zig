//! Covers src/chip/core/cpu/text/text.zig.
const std = @import("std");
const ra8 = @import("ra8");
const text = ra8.chip.core.cpu.decode.text.text;

test "registers use the standard UAL names" {
    try std.testing.expectEqualStrings("sb", text.names[9]);
    try std.testing.expectEqualStrings("ip", text.names[12]);
    try std.testing.expectEqualStrings("pc", text.names[15]);
}

test "immediates under ten are decimal and the rest hex" {
    var out: text.Text = .{};
    out.imm(9);
    out.put(" ", .{});
    out.imm(10);
    try std.testing.expectEqualStrings("#9 #0xa", out.slice());
}

test "regs2 and regs3 join operands with a comma and a space" {
    var out: text.Text = .{};
    out.regs3("adds", 0, 1, 13);
    try std.testing.expectEqualStrings("adds r0, r1, sp", out.slice());
    out = .{};
    out.regs2("mov", 8, 14);
    try std.testing.expectEqualStrings("mov r8, lr", out.slice());
}

test "text past the buffer is dropped, not overrun" {
    var out: text.Text = .{};
    var i: usize = 0;
    while (i < 20) : (i += 1) out.put("abcdef", .{});
    try std.testing.expect(out.len <= out.buffer.len);
}

test "low reads three bits at an offset" {
    try std.testing.expectEqual(@as(u4, 5), text.low(0x0028, 3));
}
