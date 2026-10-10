const std = @import("std");
const ra8 = @import("ra8");
const case = ra8.chip.core.cpu.fpu.case;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

test "a case carries its rounding mode, FZ and DN into FPSCR" {
    const c = case.Binary(u32){ .a = 0, .b = 0, .mode = .zero, .fz = 1, .dn = 1 };
    const fpscr = c.fpscr();
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.fpscr.RMode.zero, fpscr.rmode);
    try std.testing.expectEqual(@as(u1, 1), fpscr.fz);
    try std.testing.expectEqual(@as(u1, 1), fpscr.dn);
}

test "flagsOf keeps only the cumulative exception flags" {
    const fpscr = Fpscr{ .ioc = 1, .idc = 1, .n = 1, .dn = 1 };
    try std.testing.expectEqual(case.flag.ioc | case.flag.idc, case.flagsOf(fpscr));
}
