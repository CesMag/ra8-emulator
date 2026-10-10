//! Tests for src/chip/periph/fault_status.zig.

const std = @import("std");
const ra8 = @import("ra8");
const status = ra8.chip.periph.fault_status;
const mpu_fault = ra8.chip.periph.mpu_fault;
const escalate = ra8.chip.periph.mpu_escalate;

test "every CFSR cause sits on its DDI0553 D1.2.11 bit" {
    const Pin = struct { cause: status.Cause, word: u32 };
    const pins = [_]Pin{
        .{ .cause = .iaccviol, .word = 0x0000_0001 },
        .{ .cause = .daccviol, .word = 0x0000_0002 },
        .{ .cause = .munstkerr, .word = 0x0000_0008 },
        .{ .cause = .mstkerr, .word = 0x0000_0010 },
        .{ .cause = .mlsperr, .word = 0x0000_0020 },
        .{ .cause = .mmarvalid, .word = 0x0000_0080 },
        .{ .cause = .ibuserr, .word = 0x0000_0100 },
        .{ .cause = .preciserr, .word = 0x0000_0200 },
        .{ .cause = .impreciserr, .word = 0x0000_0400 },
        .{ .cause = .unstkerr, .word = 0x0000_0800 },
        .{ .cause = .stkerr, .word = 0x0000_1000 },
        .{ .cause = .lsperr, .word = 0x0000_2000 },
        .{ .cause = .bfarvalid, .word = 0x0000_8000 },
        .{ .cause = .undefinstr, .word = 0x0001_0000 },
        .{ .cause = .invstate, .word = 0x0002_0000 },
        .{ .cause = .invpc, .word = 0x0004_0000 },
        .{ .cause = .nocp, .word = 0x0008_0000 },
        .{ .cause = .stkof, .word = 0x0010_0000 },
        .{ .cause = .unaligned, .word = 0x0100_0000 },
        .{ .cause = .divbyzero, .word = 0x0200_0000 },
    };
    try std.testing.expectEqual(@typeInfo(status.Cause).@"enum".field_names.len, pins.len);
    for (pins) |pin| try std.testing.expectEqual(pin.word, pin.cause.bit());
}

test "each cause belongs to the sub-register its bit falls in" {
    inline for (@typeInfo(status.Cause).@"enum".field_values) |value| {
        const cause: status.Cause = @fromBackingInt(@intCast(value));
        const mask: u32 = switch (cause.fault()) {
            .mem_manage => status.cfsr.mmfsr,
            .bus_fault => status.cfsr.bfsr,
            .usage_fault => status.cfsr.ufsr,
            // SecureFault reports in SFSR, never in CFSR, so no cause
            // may map to it; a zero mask fails the check below if one does.
            .secure_fault => 0,
        };
        try std.testing.expect(cause.bit() & mask != 0);
    }
}

test "the defined CFSR bits leave the reserved ones out" {
    try std.testing.expectEqual(@as(u32, 0x031F_BFBB), status.cfsr.defined);
    try std.testing.expectEqual(@as(u32, 0xC000_0002), status.hfsr.defined);
}

test "a precise bus error decodes to its cause and the valid address flag" {
    const found = status.decode(0x0000_8200);
    try std.testing.expectEqualSlices(status.Cause, &.{ .preciserr, .bfarvalid }, found.constSlice());
}

test "reserved CFSR bits are dropped rather than named" {
    const found = status.decode(0xFCE0_4044 | status.Cause.divbyzero.bit());
    try std.testing.expectEqualSlices(status.Cause, &.{.divbyzero}, found.constSlice());
}

test "a word with every cause set decodes to all of them in bit order" {
    const found = status.decode(0xFFFF_FFFF);
    try std.testing.expectEqual(@typeInfo(status.Cause).@"enum".field_names.len, found.len);
    var last: u5 = 0;
    for (found.constSlice(), 0..) |cause, i| {
        if (i > 0) try std.testing.expect(@backingInt(cause) > last);
        last = @backingInt(cause);
    }
}

test "an escalated HardFault decodes as forced" {
    const found = status.decodeHard(0x4000_0000);
    try std.testing.expectEqualSlices(status.Hard, &.{.forced}, found.constSlice());
    try std.testing.expectEqual(@as(usize, 0), status.decodeHard(0x3FFF_FFFD).len);
}

test "the MPU's MemManage bits and the escalation's FORCED come from this table" {
    try std.testing.expectEqual(status.Cause.iaccviol.bit(), mpu_fault.mmfsr.iaccviol);
    try std.testing.expectEqual(status.Cause.daccviol.bit(), mpu_fault.mmfsr.daccviol);
    try std.testing.expectEqual(status.Cause.mmarvalid.bit(), mpu_fault.mmfsr.mmarvalid);
    try std.testing.expectEqual(status.Hard.forced.bit(), escalate.hfsr.forced);
}

test "the fault line is silent when CFSR, HFSR and SFSR are clear" {
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try status.line(&stream, .{});
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "the fault line names INVSTATE and HFSR.FORCED (RA8EMU-394)" {
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try status.line(&stream, .{ .cfsr = 0x0002_0000, .hfsr = 0x4000_0000 });
    try std.testing.expectEqualStrings("faults: CFSR 0x00020000 invstate, HFSR 0x40000000 forced, SFSR 0x00000000\n", stream.buffered());
}
