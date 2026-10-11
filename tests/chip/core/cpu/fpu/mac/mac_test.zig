const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.chip.core.cpu.fpu.format;
const mac = ra8.chip.core.cpu.fpu.mac;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

test "the four forms agree on 1, 2 and 3 in single precision" {
    var fpscr = Fpscr{};
    const d: u32 = 0x3F80_0000;
    const n: u32 = 0x4000_0000;
    const m: u32 = 0x4040_0000;
    try std.testing.expectEqual(@as(u32, 0x40E0_0000), mac.mla(format.single, d, n, m, &fpscr));
    try std.testing.expectEqual(@as(u32, 0xC0A0_0000), mac.mls(format.single, d, n, m, &fpscr));
    try std.testing.expectEqual(@as(u32, 0xC0E0_0000), mac.nmla(format.single, d, n, m, &fpscr));
    try std.testing.expectEqual(@as(u32, 0x40A0_0000), mac.nmls(format.single, d, n, m, &fpscr));
    try std.testing.expectEqual(Fpscr{}, fpscr);
}

test "flags from the multiply survive the add" {
    var fpscr = Fpscr{};
    _ = mac.mla(format.single, 0x0000_0000, 0x3F80_0001, 0x3F80_0001, &fpscr);
    try std.testing.expectEqual(@as(u1, 1), fpscr.ixc);
}
