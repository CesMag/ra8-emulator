//! Covers src/chip/core/cpu/ops/fp_mem.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fp_mem = ra8.chip.core.cpu.ops.fp.mem;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;

/// 64 bytes of RAM at 0x2000_0000.
const Ram = struct {
    const base: u32 = 0x2000_0000;
    bytes: [64]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slot(self: *Ram, address: u32, len: usize) bus.Error![]u8 {
        if (address < base or address - base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slot(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slot(address, from.len), from);
    }

    fn word(self: *Ram, address: u32) u32 {
        return std.mem.readInt(u32, self.bytes[address - base ..][0..4], .little);
    }

    fn put(self: *Ram, address: u32, value: u32) void {
        std.mem.writeInt(u32, self.bytes[address - base ..][0..4], value, .little);
    }
};

fn at(address: u32, hw1: u16, hw2: u16) Instr {
    return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, instr: Instr) !void {
    const exec = fp_mem.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn claimed(hw1: u16, hw2: u16) bool {
    return fp_mem.group.decode(at(0, hw1, hw2)) != null;
}

test "vstr s1, [r0, #4] then vldr s2, [r0, #4]" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(0, Ram.base);
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    try run(&cpu, at(0, 0xEDC0, 0x0A01));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(Ram.base + 4));
    try run(&cpu, at(0, 0xED90, 0x1A01));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(2));
}

test "vldr d1, [r1, #-8] reads low word first" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.put(Ram.base + 8, 0x5566_7788);
    ram.put(Ram.base + 12, 0x1122_3344);
    cpu.regs.set(1, Ram.base + 16);
    try run(&cpu, at(0, 0xED11, 0x1B02));
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), cpu.fp.bank.readD(1));
}

test "vldr s0, [pc, #8] aligns the PC" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.put(Ram.base + 12, 0xCAFE_F00D);
    try run(&cpu, at(Ram.base + 2, 0xED9F, 0x0A02));
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.fp.bank.readS(0));
}

test "vpush {d0-d1} then vpop {d0-d1} round-trips and moves SP" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(13, Ram.base + 32);
    cpu.fp.bank.writeD(0, 0x0102_0304_0506_0708);
    cpu.fp.bank.writeD(1, 0x1112_1314_1516_1718);
    try run(&cpu, at(0, 0xED2D, 0x0B04));
    try std.testing.expectEqual(Ram.base + 16, cpu.regs.get(13));
    try std.testing.expectEqual(@as(u32, 0x0506_0708), ram.word(Ram.base + 16));
    try std.testing.expectEqual(@as(u32, 0x1112_1314), ram.word(Ram.base + 28));
    cpu.fp.bank.writeD(0, 0);
    cpu.fp.bank.writeD(1, 0);
    try run(&cpu, at(0, 0xECBD, 0x0B04));
    try std.testing.expectEqual(Ram.base + 32, cpu.regs.get(13));
    try std.testing.expectEqual(@as(u64, 0x1112_1314_1516_1718), cpu.fp.bank.readD(1));
}

test "vstmia r2, {s3-s5} without writeback" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(2, Ram.base);
    for (3..6) |n| cpu.fp.bank.writeS(@intCast(n), @intCast(n * 0x10));
    try run(&cpu, at(0, 0xECC2, 0x1A03));
    try std.testing.expectEqual(Ram.base, cpu.regs.get(2));
    try std.testing.expectEqual(@as(u32, 0x50), ram.word(Ram.base + 8));
}

test "a faulting access leaves Rn alone" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(13, Ram.base + 4);
    try std.testing.expectError(bus.Error.Unmapped, run(&cpu, at(0, 0xED2D, 0x0B04)));
    try std.testing.expectEqual(Ram.base + 4, cpu.regs.get(13));
}

test "unclaimed: 64-bit transfers, VLLDM, VSCCLRM, VSTR to PC, D16+, 16-bit VLDM and PC VSTR.16, empty lists" {
    try std.testing.expect(!claimed(0xEC47, 0x6B13));
    try std.testing.expect(!claimed(0xEC30, 0x0A00));
    try std.testing.expect(!claimed(0xEC9F, 0x0A04));
    try std.testing.expect(!claimed(0xED8F, 0x0A01));
    try std.testing.expect(!claimed(0xEDD0, 0x0B00));
    try std.testing.expect(!claimed(0xEC90, 0x0901));
    try std.testing.expect(!claimed(0xED8F, 0x0901));
    try std.testing.expect(!claimed(0xEDB0, 0x0901));
    try std.testing.expect(!claimed(0xECBD, 0x0B00));
    try std.testing.expect(!claimed(0xEDBD, 0x0B04));
    try std.testing.expect(claimed(0xED2D, 0x8A08));
}

test "vstr.16 s1, [r0, #6] then vldr.16 s2, [r0, #6] zero the top half" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(0, Ram.base);
    ram.put(Ram.base + 8, 0x5555_5555);
    cpu.fp.bank.writeS(1, 0xFFFF_3C00);
    try run(&cpu, at(0, 0xEDC0, 0x0903));
    try std.testing.expectEqual(@as(u32, 0x3C00_0000), ram.word(Ram.base + 4));
    try std.testing.expectEqual(@as(u32, 0x5555_5555), ram.word(Ram.base + 8));
    cpu.fp.bank.writeS(2, 0xFFFF_FFFF);
    try run(&cpu, at(0, 0xED90, 0x1903));
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.fp.bank.readS(2));
}

test "vldr.16 s0, [r1, #-2] and vldr.16 s0, [pc, #4]" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.put(Ram.base + 4, 0xBEEF_0000);
    ram.put(Ram.base + 8, 0xAAAA_1234);
    cpu.regs.set(1, Ram.base + 8);
    try run(&cpu, at(0, 0xED11, 0x0901));
    try std.testing.expectEqual(@as(u32, 0xBEEF), cpu.fp.bank.readS(0));
    try run(&cpu, at(Ram.base + 2, 0xED9F, 0x0902));
    try std.testing.expectEqual(@as(u32, 0x1234), cpu.fp.bank.readS(0));
}

const SystemRegister = struct { name: []const u8, regh: u1, regl: u4 };
const system_registers = [_]SystemRegister{
    .{ .name = "FPSCR", .regh = 0, .regl = 1 },
    .{ .name = "FPSCR_nzcvqc", .regh = 0, .regl = 2 },
    .{ .name = "VPR", .regh = 1, .regl = 4 },
    .{ .name = "P0", .regh = 1, .regl = 5 },
    .{ .name = "FPCXT_NS", .regh = 1, .regl = 6 },
    .{ .name = "FPCXT_S", .regh = 1, .regl = 7 },
};

const AddressForm = struct { name: []const u8, p: u1, w: u1 };
const address_forms = [_]AddressForm{
    .{ .name = "offset", .p = 1, .w = 0 },
    .{ .name = "pre-index", .p = 1, .w = 1 },
    .{ .name = "post-index", .p = 0, .w = 1 },
};

fn systemInstr(reg: SystemRegister, form: AddressForm, load: bool) Instr {
    const hw1: u16 = 0xEC00 | (@as(u16, form.p) << 8) | (1 << 7) |
        (@as(u16, reg.regh) << 6) | (@as(u16, form.w) << 5) |
        (@as(u16, @intFromBool(load)) << 4);
    const hw2: u16 = (@as(u16, reg.regl) << 12) | 0x0F80 | 2;
    return at(0, hw1, hw2);
}

fn expectedAddress(base: u32, form: AddressForm) u32 {
    return if (form.p == 1) base + 8 else base;
}

fn expectedBase(base: u32, form: AddressForm) u32 {
    return if (form.w == 1) base + 8 else base;
}

test "VLDR and VSTR system registers cover each register and addressing form" {
    const stored: u32 = 0x8000_0015;
    const loaded: u32 = 0xA5C3_5A69;
    for (system_registers) |reg| {
        for (address_forms) |form| {
            var ram: Ram = .{};
            var cpu: Cpu = .{ .bus = ram.view() };
            const base = Ram.base + 16;
            const address = expectedAddress(base, form);
            cpu.regs.set(0, base);
            cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.fpca | ra8.chip.core.cpu.regs.control_bits.sfpa;
            cpu.fp.fpscr = Fpscr.fromBits(stored);
            cpu.fp.vpr = @bitCast(stored);

            const store = systemInstr(reg, form, false);
            try std.testing.expect(claimed(store.hw1, store.hw2));
            try run(&cpu, store);
            const expected_store = switch (reg.regl | (@as(u4, reg.regh) << 3)) {
                2 => stored & 0xF800_0000,
                13 => stored & 0xFFFF,
                6, 7 => stored,
                else => stored,
            };
            try std.testing.expectEqual(expected_store, ram.word(address));
            try std.testing.expectEqual(expectedBase(base, form), cpu.regs.get(0));

            cpu.regs.set(0, base);
            ram.put(address, loaded);
            cpu.fp.fpscr = Fpscr.fromBits(0x0123_4567);
            cpu.fp.vpr = @bitCast(@as(u32, 0x1234_5678));
            const load = systemInstr(reg, form, true);
            try run(&cpu, load);
            try std.testing.expectEqual(expectedBase(base, form), cpu.regs.get(0));
            switch (reg.regl | (@as(u4, reg.regh) << 3)) {
                1 => try std.testing.expectEqual(loaded & 0xFFCF_009F, cpu.fp.fpscr.bits()),
                2 => try std.testing.expectEqual((@as(u32, 0x0123_4567) & 0xFFCF_009F & 0x07FF_FFFF) | (loaded & 0xF800_0000), cpu.fp.fpscr.bits()),
                12 => try std.testing.expectEqual(loaded & 0x00FF_FFFF, @as(u32, @bitCast(cpu.fp.vpr))),
                13 => try std.testing.expectEqual(@as(u16, @truncate(loaded)), cpu.fp.vpr.p0),
                14, 15 => {
                    try std.testing.expectEqual(@as(u1, @truncate(loaded >> 31)), @as(u1, @truncate(cpu.regs.control >> 3)));
                    try std.testing.expectEqual(loaded & 0x0FFF_FFFF & 0xFFCF_009F, cpu.fp.fpscr.bits());
                },
                else => unreachable,
            }
            _ = reg.name;
            _ = form.name;
        }
    }
}

test "inactive FPCXT_NS VLDR skips ExecuteFPCheck and memory access" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(0, Ram.base + 16);
    cpu.fp.fpscr = Fpscr.fromBits(0x1234_5678);
    const instr = systemInstr(system_registers[4], address_forms[1], true);
    const exec = ra8.chip.core.cpu.decode.decode(instr).?.exec;
    try exec(&cpu, instr);
    try std.testing.expectEqual(@as(u32, 0x1234_5678) & 0xFFCF_009F, cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & ra8.chip.core.cpu.regs.control_bits.fpca);
    try std.testing.expectEqual(Ram.base + 24, cpu.regs.get(0));
}

test "VLDR VPR runs unprivileged and keeps the reserved bits zero" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    const base = Ram.base + 16;
    cpu.regs.set(0, base);
    cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.fpca | ra8.chip.core.cpu.regs.control_bits.npriv;
    ram.put(base + 8, 0xFF12_3456);
    try run(&cpu, systemInstr(system_registers[2], address_forms[0], true));
    try std.testing.expectEqual(@as(u32, 0x0012_3456), @as(u32, @bitCast(cpu.fp.vpr)));
}
