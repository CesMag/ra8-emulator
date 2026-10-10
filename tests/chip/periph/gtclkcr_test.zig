const std = @import("std");
const ra8 = @import("ra8");
const gtclkcr = ra8.chip.periph.gtclkcr;
const mstp = ra8.chip.periph.mstp;

const Fixture = struct {
    modules: mstp.Mstp,
    unit: gtclkcr.Unit,

    fn init(self: *Fixture) void {
        self.modules = .{};
        self.unit = gtclkcr.Unit.init(&self.modules);
    }

    /// Clear MSTPCRE.MSTPE31, the way ra8_mstp_enable releases the bank.
    fn release(self: *Fixture) void {
        const mstpcre = mstp.win_base + 0x10;
        const now = self.modules.readReg(mstpcre, 4);
        self.modules.applyWrite(mstpcre, 4, now & ~(@as(u32, 1) << 31));
    }

    fn store(self: *Fixture, value: u32) void {
        self.unit.write(gtclkcr.win_base, 4, value);
    }
};

test "nothing is said before firmware writes" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expect(fix.unit.quiet());
    try std.testing.expect(!fix.unit.programmed());
}

test "the bank comes up module-stopped, so the store lands" {
    var fix: Fixture = undefined;
    fix.init();
    try std.testing.expect(fix.modules.stopped(gtclkcr.bank_base));
    fix.store(gtclkcr.bit.bpen);
    try std.testing.expect(fix.unit.programmed());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.stores);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.prohibited_running);
}

test "a store after the module-stop release is prohibited" {
    var fix: Fixture = undefined;
    fix.init();
    fix.release();
    try std.testing.expect(!fix.modules.stopped(gtclkcr.bank_base));
    fix.store(gtclkcr.bit.bpen);
    try std.testing.expect(!fix.unit.programmed());
    try std.testing.expectEqual(@as(u32, 1), fix.unit.prohibited_running);
    try std.testing.expectEqual(@as(u32, 0), fix.unit.stores);
}

test "a prohibited store leaves what was there" {
    var fix: Fixture = undefined;
    fix.init();
    fix.store(gtclkcr.bit.bpen);
    fix.release();
    fix.store(0);
    try std.testing.expect(fix.unit.programmed());
    try std.testing.expectEqual(@as(u32, gtclkcr.bit.bpen), fix.unit.read(gtclkcr.win_base, 4));
}

test "the driver's own order works and the reverse does not" {
    var early: Fixture = undefined;
    early.init();
    early.store(gtclkcr.bit.bpen);
    early.release();
    try std.testing.expect(early.unit.programmed());

    var late: Fixture = undefined;
    late.init();
    late.release();
    late.store(gtclkcr.bit.bpen);
    try std.testing.expect(!late.unit.programmed());
}

test "a prohibited store alone breaks quiet" {
    var fix: Fixture = undefined;
    fix.init();
    fix.release();
    fix.store(gtclkcr.bit.bpen);
    try std.testing.expect(!fix.unit.quiet());
}

test "the register reads back what landed" {
    var fix: Fixture = undefined;
    fix.init();
    fix.store(gtclkcr.bit.bpen);
    try std.testing.expectEqual(@as(u32, 1), fix.unit.read(gtclkcr.win_base, 4));
}
