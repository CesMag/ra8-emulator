//! Covers src/chip/core/cpu/ops/pac.zig.
const std = @import("std");
const ra8 = @import("ra8");
const qarma = ra8.chip.core.cpu.ops.qarma;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const bus = ra8.chip.core.cpu.bus;
const memmap = ra8.chip.core.memmap;
const pac = ra8.chip.core.cpu.ops.pac;

fn instr(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0x100, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn execute(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const i = instr(hw1, hw2);
    const run = pac.group.decode(i) orelse return error.NotClaimed;
    try run(cpu, i);
}

fn enabledCpu() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.control = ra8.chip.core.cpu.regs.control_bits.pac_en;
    cpu.regs.pac_key_p = .{ 1, 2, 3, 4 };
    cpu.regs.lr = 0x0800_1235;
    cpu.regs.msp = 0x2000_1000;
    return cpu;
}

test "PAC, AUT authenticate an unchanged LR and fault on a corrupted return address" {
    var cpu = enabledCpu();
    try execute(&cpu, 0xF3AF, 0x801D); // pac r12, lr, sp
    const signed = cpu.regs.low[12];
    try std.testing.expect(signed != 0);
    try execute(&cpu, 0xF3AF, 0x802D); // aut r12, lr, sp

    cpu.regs.lr ^= 4;
    try std.testing.expectError(error.InvalidState, execute(&cpu, 0xF3AF, 0x802D));
}

const FaultBus = struct {
    code: [4]u8 = .{ 0xAF, 0xF3, 0x2D, 0x80 }, // aut r12, lr, sp
    cfsr: u32 = 0,
    shcsr: u32 = 1 << 18,

    fn view(self: *FaultBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *FaultBus = @ptrCast(@alignCast(ctx));
        if (address >= 0x100 and address + into.len <= 0x104) {
            @memcpy(into, self.code[address - 0x100 ..][0..into.len]);
            return;
        }
        const value = if (address == memmap.scb.cfsr) self.cfsr else if (address == memmap.scb.shcsr) self.shcsr else 0;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        if (address <= memmap.scb.cfsr and address + into.len > memmap.scb.cfsr) {
            @memcpy(into, bytes[0..into.len]);
            return;
        }
        if (address <= memmap.scb.shcsr and address + into.len > memmap.scb.shcsr) {
            @memcpy(into, bytes[0..into.len]);
            return;
        }
        if (address < 4) {
            @memset(into, 0);
            return;
        }
        return error.Unmapped;
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *FaultBus = @ptrCast(@alignCast(ctx));
        if (address == memmap.scb.cfsr and from.len == 4) {
            self.cfsr = std.mem.readInt(u32, from[0..4], .little);
            return;
        }
        return error.Unmapped;
    }
};

test "a failed AUT reaches the UsageFault INVSTATE latch" {
    var memory: FaultBus = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    cpu.regs.pc = 0x100;
    cpu.regs.xpsr = ra8.chip.core.cpu.regs.xpsr_bits.thumb;
    cpu.regs.control = ra8.chip.core.cpu.regs.control_bits.pac_en;
    cpu.regs.lr = 0x0800_1235;
    cpu.regs.low[12] = 0x1234;
    const stopped = cpu.step().?;
    try std.testing.expectEqual(@as(u32, 0x100), stopped.invalid_state);
    try std.testing.expectEqual(@as(u32, 1 << 17), memory.cfsr);
}

test "PACG and AUTG use selected GPRs, BXAUT branches after authentication" {
    var cpu = enabledCpu();
    cpu.regs.low[1] = 0x0800_4567;
    cpu.regs.low[2] = 0x2000_0020;
    try execute(&cpu, 0xFB61, 0xF002); // pacg r0, r1, r2
    try std.testing.expectEqual(qarma.pac(cpu.regs.low[1], cpu.regs.low[2], cpu.regs.pac_key_p), cpu.regs.low[0]);
    try execute(&cpu, 0xFB51, 0x0F02); // autg r0, r1, r2
    try execute(&cpu, 0xFB51, 0x0F12); // bxaut r1, r2, r0
    try std.testing.expectEqual(@as(u32, 0x0800_4566), cpu.regs.pc);
}

test "BXAUT with a wrong code in Ra faults and does not branch" {
    var cpu = enabledCpu();
    cpu.regs.pc = 0x0800_0100;
    cpu.regs.low[1] = 0x0800_4567;
    cpu.regs.low[2] = 0x2000_0020;
    cpu.regs.low[0] = qarma.pac(cpu.regs.low[1], cpu.regs.low[2], cpu.regs.pac_key_p) ^ 1;
    try std.testing.expectError(error.InvalidState, execute(&cpu, 0xFB51, 0x0F12)); // bxaut r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0x0800_0100), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x0800_4567), cpu.regs.low[1]);
}

test "disabled PAC instructions are inert and BXAUT still branches" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.lr = 0x0800_1235;
    cpu.regs.low[1] = 0x0800_1235;
    try execute(&cpu, 0xF3AF, 0x801D);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[12]);
    cpu.regs.lr ^= 4;
    try execute(&cpu, 0xF3AF, 0x802D); // AUT is inert when disabled
    cpu.regs.low[0] = 0xDEAD_BEEF;
    cpu.regs.low[2] = 0x2000_0010;
    try execute(&cpu, 0xFB61, 0xF002); // PACG leaves its destination untouched
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.regs.low[0]);
    try execute(&cpu, 0xFB51, 0x0F02); // AUTG is inert when disabled
    try execute(&cpu, 0xFB51, 0x0F12); // bxaut r0, r1, r2 skips the check, then branches
    try std.testing.expectEqual(@as(u32, 0x0800_1234), cpu.regs.pc);
}

test "the instruction group claims PAC, PACBTI, AUT, PACG, AUTG and BXAUT" {
    for ([_]Instr{
        instr(0xF3AF, 0x800D), instr(0xF3AF, 0x801D), instr(0xF3AF, 0x802D),
        instr(0xFB61, 0xF002), instr(0xFB51, 0x0F02), instr(0xFB51, 0x0F12),
    }) |i| try std.testing.expect(pac.group.decode(i) != null);
    try std.testing.expect(pac.group.decode(instr(0xFB51, 0x0F32)) == null);
}

test "LR is a legal Rd, Ra and BXAUT Rn; SP and PC are refused" {
    for ([_]Instr{
        instr(0xFB5E, 0xCF1D), instr(0xFB61, 0xFE02), instr(0xFB51, 0xEF02),
    }) |i| try std.testing.expect(pac.group.decode(i) != null);
    for ([_]Instr{
        instr(0xFB5D, 0xCF1E), instr(0xFB61, 0xFD02), instr(0xFB51, 0xDF02), instr(0xFB51, 0xFF02),
    }) |i| try std.testing.expect(pac.group.decode(i) == null);
}

test "bxaut ip, lr, sp returns through an authenticated LR and faults on a bad code" {
    var cpu = enabledCpu();
    cpu.regs.low[12] = qarma.pac(cpu.regs.lr, cpu.regs.sp(), cpu.regs.pac_key_p);
    try execute(&cpu, 0xFB5E, 0xCF1D);
    try std.testing.expectEqual(@as(u32, 0x0800_1234), cpu.regs.pc);
    cpu.regs.pc = 0x0800_0100;
    cpu.regs.low[12] ^= 1;
    try std.testing.expectError(error.InvalidState, execute(&cpu, 0xFB5E, 0xCF1D));
    try std.testing.expectEqual(@as(u32, 0x0800_0100), cpu.regs.pc);
}

test "PAC enable is selected from the active security and privilege CONTROL bank" {
    const State = ra8.chip.core.banked.State;
    const states = [_]State{ .secure, .non_secure };
    for (states) |state| {
        for ([_]bool{ true, false }) |privileged| {
            var cpu = enabledCpu();
            cpu.regs.control = 0;
            if (state == .non_secure) cpu.banked.switchTo(&cpu.regs, state);
            const bit = if (privileged) ra8.chip.core.cpu.regs.control_bits.pac_en else ra8.chip.core.cpu.regs.control_bits.upac_en;
            cpu.regs.control = bit | (if (privileged) 0 else ra8.chip.core.cpu.regs.control_bits.npriv);
            cpu.regs.low[12] = 0xA5A5_5A5A;
            try execute(&cpu, 0xF3AF, 0x801D);
            const key = if (privileged) cpu.regs.pac_key_p else cpu.regs.pac_key_u;
            try std.testing.expectEqual(qarma.pac(cpu.regs.lr, cpu.regs.sp(), key), cpu.regs.low[12]);
        }
    }
}
