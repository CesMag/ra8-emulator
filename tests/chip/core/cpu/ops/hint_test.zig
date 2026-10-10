//! Covers src/chip/core/cpu/ops/hint.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hint = ra8.chip.core.cpu.ops.hint;

fn narrow(hw1: u16) ?ra8.chip.core.cpu.op.Exec {
    return hint.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 });
}

fn wide(hw2: u16) ?ra8.chip.core.cpu.op.Exec {
    return hint.group.decode(.{ .address = 0, .hw1 = 0xF3AF, .hw2 = hw2, .size = 4 });
}

test "both NOP widths decode" {
    const e = hint.encodings;
    try std.testing.expect(narrow(e.nop_t1) != null);
    try std.testing.expect(wide(e.nop_t2_hw2) != null);
}

test "yield, wfe, wfi and sev decode in both widths" {
    // bf10 yield, bf20 wfe, bf30 wfi, bf40 sev
    for ([_]u16{ 0xBF10, 0xBF20, 0xBF30, 0xBF40 }) |hw1| try std.testing.expect(narrow(hw1) != null);
    for ([_]u16{ 0x8001, 0x8002, 0x8003, 0x8004 }) |hw2| try std.testing.expect(wide(hw2) != null);
}

test "IT and non-BTI PAC instructions remain unclaimed" {
    // bf08 and bf18 are IT (nonzero mask)
    for ([_]u16{ 0xBF08, 0xBF18 }) |hw1| try std.testing.expect(narrow(hw1) == null);
    // f3af 800d pacbti, 800f bti, 801d pac, 802d aut (arm-none-eabi-as 13.3)
    try std.testing.expect(wide(0x800F) != null);
    for ([_]u16{ 0x800D, 0x801D, 0x802D }) |hw2| try std.testing.expect(wide(hw2) == null);
    // hw2[15:8] not 0x80 is not the hint space
    try std.testing.expect(wide(0x8105) == null);
}

/// Runs a wide hint and checks it changed nothing the hints can touch.
fn expectWideNop(hw2: u16) !void {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined, .source = null };
    cpu.regs.pc = 0x100;
    cpu.regs.xpsr = 0x0100_0000;
    const exec = wide(hw2) orelse return error.NotClaimed;
    try exec(&cpu, .{ .address = 0xFC, .hw1 = 0xF3AF, .hw2 = hw2, .size = 4 });
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.regs.xpsr);
    try std.testing.expect(!cpu.event);
}

test "dbg, esb, csdb and the reserved wide hints run as NOP" {
    // f3af 80f5 dbg #5, 8010 esb, 8014 csdb, 8005 and 80ef reserved
    for ([_]u16{ 0x80F5, 0x80F0, 0x80FF, 0x8010, 0x8014, 0x8005, 0x80EF }) |hw2| try expectWideNop(hw2);
}

test "the reserved narrow hints run as NOP" {
    // bf50 to bff0: hint numbers 5 to 15
    var n: u16 = 5;
    while (n <= 15) : (n += 1) {
        var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
        try runHint(&cpu, 0xBF00 | (n << 4));
        try std.testing.expect(!cpu.event);
    }
}

test "wfi falls straight through" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
    cpu.regs.pc = 0x100;
    const exec = narrow(0xBF30).?;
    try exec(&cpu, .{ .address = 0xFE, .hw1 = 0xBF30, .size = 2 });
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
}

fn runHint(cpu: *ra8.chip.core.cpu.cpu.Cpu, hw1: u16) !void {
    const exec = narrow(hw1).?;
    try exec(cpu, .{ .address = 0xFE, .hw1 = hw1, .size = 2 });
}

test "sev sets the event register in both widths" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
    try runHint(&cpu, 0xBF40);
    try std.testing.expect(cpu.event);
    cpu.event = false;
    const exec = wide(0x8004).?;
    try exec(&cpu, .{ .address = 0xFC, .hw1 = 0xF3AF, .hw2 = 0x8004, .size = 4 });
    try std.testing.expect(cpu.event);
}

test "wfe with the event set clears it and completes" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined, .event = true };
    cpu.regs.pc = 0x100;
    try runHint(&cpu, 0xBF20);
    try std.testing.expect(!cpu.event);
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
}

test "wfe with the event clear leaves it clear" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
    try runHint(&cpu, 0xBF20);
    try std.testing.expect(!cpu.event);
}

test "sev then wfe pairs off, and nop, yield and wfi leave the event alone" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
    try runHint(&cpu, 0xBF40);
    for ([_]u16{ 0xBF00, 0xBF10, 0xBF30 }) |hw1| try runHint(&cpu, hw1);
    try std.testing.expect(cpu.event);
    try runHint(&cpu, 0xBF20);
    try std.testing.expect(!cpu.event);
}

test "the complete narrow hint number table decodes and reserved values are NOPs" {
    var number: u16 = 0;
    while (number <= 15) : (number += 1) {
        const hw1 = 0xBF00 | (number << 4);
        const exec = narrow(hw1) orelse return error.UnclaimedHint;
        var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
        cpu.regs.pc = 0x100;
        cpu.regs.xpsr = 0x0100_0000;
        try exec(&cpu, .{ .address = 0xFE, .hw1 = hw1, .size = 2 });
        if (number == hint.encodings.wfe or number == hint.encodings.wfi) {
            try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
        } else if (number == hint.encodings.sev) {
            try std.testing.expect(cpu.event);
        } else {
            try std.testing.expect(!cpu.event);
            try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.regs.xpsr);
        }
    }
}

test "the complete wide hint number table claims architectural hints only" {
    var number: u16 = 0;
    while (number <= 0xFF) : (number += 1) {
        const hw2 = 0x8000 | number;
        const exec = wide(hw2);
        const pacbti_number = number == 0x0D or number == 0x1D or number == 0x2D;
        try std.testing.expectEqual(!pacbti_number, exec != null);
        if (exec) |run| {
            var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
            cpu.regs.pc = 0x100;
            cpu.regs.xpsr = 0x0100_0000;
            run(&cpu, .{ .address = 0xFC, .hw1 = 0xF3AF, .hw2 = hw2, .size = 4 }) catch return error.ExecutionFailed;
            if (number == hint.encodings.sev) {
                try std.testing.expect(cpu.event);
            } else if (number == hint.encodings.wfe) {
                try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
            } else if (number != 0x0F) {
                try std.testing.expect(!cpu.event);
                try std.testing.expectEqual(@as(u32, 0x0100_0000), cpu.regs.xpsr);
            }
        }
    }
}
