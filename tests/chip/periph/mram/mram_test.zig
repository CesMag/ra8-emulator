//! Covers src/chip/periph/mram/mram.zig: the controller window, the command the
//! sequencer hands it, and every refusal in between.
const std = @import("std");
const ra8 = @import("ra8");

const mram = ra8.chip.periph.mram;
const maci = ra8.chip.periph.maci;
const otp = ra8.chip.periph.mram.otp;

const port = mram.command.base;
const enter_pe: u32 = mram.field.key | mram.field.mentry;
const leave_pe: u32 = mram.field.key;

fn address(offset: u32) u32 {
    return mram.regs.base + offset;
}

/// Enter program/erase mode, point MSADDR somewhere legal, and run one
/// Program of `halfwords`.
fn programAt(unit: *mram.Mram, target: u32, halfwords: []const u16) void {
    unit.write(address(mram.regs.off_mentryr), 4, enter_pe);
    unit.write(address(mram.regs.off_msaddr), 4, target);
    stream(unit, maci.opcode.program, halfwords);
}

fn stream(unit: *mram.Mram, opener: u8, halfwords: []const u16) void {
    unit.commandWrite(1, opener);
    unit.commandWrite(1, @intCast(halfwords.len));
    for (halfwords) |value| unit.commandWrite(2, value);
    unit.commandWrite(1, maci.opcode.final);
}

test "a fresh controller is quiet, out of program mode and ready" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.read(address(mram.regs.off_mentryr), 4));
    try std.testing.expectEqual(mram.field.mrdy, unit.read(address(mram.regs.off_mstatr), 4));
}

test "MENTRYR takes the key and reports the mode bit" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 4, enter_pe);
    try std.testing.expectEqual(mram.field.mentry, unit.read(address(mram.regs.off_mentryr), 4));
    unit.write(address(mram.regs.off_mentryr), 4, leave_pe);
    try std.testing.expectEqual(@as(u32, 0), unit.read(address(mram.regs.off_mentryr), 4));
}

test "a keyless MENTRYR write is refused, where dev enters anyway" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 4, mram.field.mentry);
    try std.testing.expectEqual(@as(u32, 0), unit.read(address(mram.regs.off_mentryr), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.entry.keyless);
}

test "a byte store at MENTRYR carries no key, where the shadow used to vouch" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 4, enter_pe);
    unit.write(address(mram.regs.off_mentryr), 4, leave_pe);
    unit.write(address(mram.regs.off_mentryr), 1, mram.field.mentry);
    try std.testing.expectEqual(@as(u32, 0), unit.read(address(mram.regs.off_mentryr), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.entry.narrow_writes);
    try std.testing.expectEqual(@as(u32, 0), unit.entry.keyless);
}

test "a byte store of the key half alone does not move the mode" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr) + 1, 1, 0xAA);
    try std.testing.expectEqual(@as(u32, 0), unit.read(address(mram.regs.off_mentryr), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.entry.narrow_writes);
}

test "a halfword store names the whole of MENTRYR and is taken" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 2, enter_pe);
    try std.testing.expectEqual(mram.field.mentry, unit.read(address(mram.regs.off_mentryr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.entry.narrow_writes);
    unit.write(address(mram.regs.off_mentryr), 2, leave_pe);
    try std.testing.expectEqual(@as(u32, 0), unit.read(address(mram.regs.off_mentryr), 4));
}

test "a refused narrow store leaves program/erase mode standing" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 4, enter_pe);
    unit.write(address(mram.regs.off_mentryr), 1, 0x00);
    try std.testing.expectEqual(mram.field.mentry, unit.read(address(mram.regs.off_mentryr), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.entry.narrow_writes);
}

test "a wrong key in a whole-register store is still counted keyless" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 2, 0x5580);
    try std.testing.expectEqual(@as(u32, 0), unit.read(address(mram.regs.off_mentryr), 4));
    try std.testing.expectEqual(@as(u32, 1), unit.entry.keyless);
    try std.testing.expectEqual(@as(u32, 0), unit.entry.narrow_writes);
}

test "the bytes above MENTRYR still merge into the shadow" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr) + 2, 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), unit.entry.narrow_writes);
    try std.testing.expectEqual(@as(u32, 0), unit.entry.keyless);
}

test "MSADDR keeps the bytes a narrow store does not name" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_msaddr), 4, 0x02E0_7600);
    unit.write(address(mram.regs.off_msaddr), 1, 0x10);
    try std.testing.expectEqual(@as(u32, 0x02E0_7610), unit.msaddr);
    try std.testing.expectEqual(@as(u32, 0x02E0_7610), unit.read(address(mram.regs.off_msaddr), 4));
}

test "a program inside the window lands in the cells" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, otp.window.lo, &[_]u16{ 0x3412, 0x7856 });
    try std.testing.expectEqual(@as(u32, 1), unit.programs);
    try std.testing.expectEqual(@as(u8, 0x12), unit.otp.byte(otp.window.lo));
    try std.testing.expectEqual(@as(u8, 0x78), unit.otp.byte(otp.window.lo + 3));
}

test "a config set is counted as its own command" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 4, enter_pe);
    unit.write(address(mram.regs.off_msaddr), 4, otp.window.lo);
    stream(&unit, maci.opcode.config_set, &[_]u16{0x00FF});
    try std.testing.expectEqual(@as(u32, 1), unit.config_sets);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
}

test "a program outside the window is rejected and locks the sequencer" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, 0x2700_0000, &[_]u16{0xFFFF});
    try std.testing.expectEqual(@as(u32, 1), unit.illegal);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
    try std.testing.expect(unit.locked);
}

test "a program into the OTA demo boot record hole is rejected" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, 0x02E0_9600, &[_]u16{0xFFFF});
    try std.testing.expectEqual(@as(u32, 1), unit.illegal);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
    try std.testing.expect(unit.locked);
}

test "a rejection is readable in MSTATR and MASTAT, where dev answers ready" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, 0x2700_0000, &[_]u16{0xFFFF});
    const expected = mram.field.mrdy | mram.field.ilgcomerr | mram.field.ilglerr;
    try std.testing.expectEqual(expected, unit.read(address(mram.regs.off_mstatr), 4));
    const access = mram.field.cmdlk | mram.field.mreae;
    try std.testing.expectEqual(access, unit.read(address(mram.regs.off_mastat), 4));
}

test "a command-locked sequencer accepts nothing" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, 0x2700_0000, &[_]u16{0xFFFF});
    programAt(&unit, otp.window.lo, &[_]u16{0x0F0F});
    try std.testing.expectEqual(@as(u32, 1), unit.locked_out);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
}

test "leaving program mode releases the lock and the latches" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, 0x2700_0000, &[_]u16{0xFFFF});
    unit.write(address(mram.regs.off_mentryr), 4, leave_pe);
    try std.testing.expect(!unit.locked);
    try std.testing.expectEqual(mram.field.mrdy, unit.read(address(mram.regs.off_mstatr), 4));
    programAt(&unit, otp.window.lo, &[_]u16{0x0F0F});
    try std.testing.expectEqual(@as(u32, 1), unit.programs);
}

test "a command without program mode entered is refused" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_msaddr), 4, otp.window.lo);
    stream(&unit, maci.opcode.program, &[_]u16{0x1234});
    try std.testing.expectEqual(@as(u32, 1), unit.outside_mode);
    try std.testing.expectEqual(@as(u32, 0), unit.programs);
}

test "a trailer on a short stream is refused, where dev commits what arrived" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 4, enter_pe);
    unit.write(address(mram.regs.off_msaddr), 4, otp.window.lo);
    unit.commandWrite(1, maci.opcode.program);
    unit.commandWrite(1, 8);
    unit.commandWrite(2, 0x1111);
    unit.commandWrite(1, maci.opcode.final);
    try std.testing.expectEqual(@as(u32, 1), unit.malformed);
    try std.testing.expectEqual(otp.window.erased, unit.otp.byte(otp.window.lo));
}

test "a rewrite of a programmed cell is refused" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, otp.window.lo, &[_]u16{0x0F0F});
    programAt(&unit, otp.window.lo, &[_]u16{0xFFFF});
    try std.testing.expectEqual(@as(u32, 1), unit.rewrites);
    try std.testing.expectEqual(@as(u32, 1), unit.programs);
    try std.testing.expectEqual(@as(u8, 0x0F), unit.otp.byte(otp.window.lo));
}

test "a program that only clears further bits still runs" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, otp.window.lo, &[_]u16{0x3F3F});
    programAt(&unit, otp.window.lo, &[_]u16{0x0F0F});
    try std.testing.expectEqual(@as(u32, 2), unit.programs);
    try std.testing.expectEqual(@as(u8, 0x0F), unit.otp.byte(otp.window.lo));
}

test "firmware cannot clear the errors it raised" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    programAt(&unit, 0x2700_0000, &[_]u16{0xFFFF});
    unit.write(address(mram.regs.off_mstatr), 4, 0);
    unit.write(address(mram.regs.off_mastat), 4, 0);
    try std.testing.expectEqual(@as(u32, 2), unit.read_only);
    try std.testing.expect(unit.read(address(mram.regs.off_mstatr), 4) & mram.field.ilglerr != 0);
}

test "a stray byte mid-stream leaves the command unrun" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    unit.write(address(mram.regs.off_mentryr), 4, enter_pe);
    unit.write(address(mram.regs.off_msaddr), 4, otp.window.lo);
    unit.commandWrite(1, maci.opcode.program);
    unit.commandWrite(1, 1);
    unit.commandWrite(2, 0x1234);
    unit.commandWrite(1, 0x55);
    try std.testing.expect(unit.quiet());
}

test "the command port reads zero" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    const block = unit.commandBlock();
    try std.testing.expectEqual(@as(u32, 0), block.readFn(block.context, port, 4));
}

test "the code-MRAM page reports idle and ready and shadows the gate" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    const status = mram.code_page.base + mram.code_page.off_mrcps;
    try std.testing.expectEqual(mram.code_page.ready, unit.codeRead(status, 4));
    unit.codeWrite(mram.code_page.base, 4, 0xA5A5_0001);
    try std.testing.expectEqual(@as(u32, 0xA5A5_0001), unit.codeRead(mram.code_page.base, 4));
}

test "the three windows are where the manual puts them" {
    var unit = mram.Mram.init(std.testing.allocator);
    defer unit.deinit();

    try std.testing.expectEqual(@as(u32, 0x4013_E000), unit.block().base);
    try std.testing.expectEqual(@as(u32, 0x4012_0000), unit.commandBlock().base);
    try std.testing.expectEqual(@as(u32, 0x4013_F000), unit.codeBlock().base);
}
