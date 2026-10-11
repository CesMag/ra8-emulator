//! Covers the Branch Future NOP implementation and its fallback branch points.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const regs = ra8.chip.core.cpu.regs;
const branch_future = ra8.chip.core.cpu.ops.branch_future;
const branch_wide = ra8.chip.core.cpu.ops.branch_wide;
const special_data = ra8.chip.core.cpu.ops.special_data;
const decode = ra8.chip.core.cpu.decode;

const Form = struct {
    name: []const u8,
    hw1: u16,
    hw2: u16,
};

const forms = [_]Form{
    .{ .name = "BF", .hw1 = 0xF0C0, .hw2 = 0xE001 },
    .{ .name = "BFX", .hw1 = 0xF0E2, .hw2 = 0xE001 },
    .{ .name = "BFL", .hw1 = 0xF080, .hw2 = 0xC001 },
    .{ .name = "BFLX", .hw1 = 0xF0F2, .hw2 = 0xE001 },
    .{ .name = "BFCSEL", .hw1 = 0xF080, .hw2 = 0xE001 },
};

fn wide(address: u32, hw1: u16, hw2: u16) Instr {
    return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn fresh() Cpu {
    return .{
        .bus = undefined,
        .regs = .{ .xpsr = regs.xpsr_bits.thumb | 0xF100_0000 },
    };
}

test "each Branch Future form decodes on M85 and retires as a NOP" {
    for (forms) |form| {
        const instr = wide(0x1000, form.hw1, form.hw2);
        const hit = decode.decodeFor(.m85, instr) orelse return error.NotDecoded;
        try std.testing.expectEqualStrings("branch_future", hit.group);
        try std.testing.expect(branch_future.group.decode(instr) != null);
        try std.testing.expect(decode.decodeFor(.m33, instr) == null);

        var cpu = fresh();
        cpu.regs.lr = 0x1234_5679;
        cpu.regs.pc = instr.address + 4;
        try hit.exec(&cpu, instr);
        try std.testing.expectEqual(instr.address + 4, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 0x1234_5679), cpu.regs.lr);
        try std.testing.expectEqual(regs.xpsr_bits.thumb | 0xF100_0000, cpu.regs.xpsr);
    }
}

test "BFL fallback BL sets LR at its branch point" {
    const branch_point: u32 = 0x1006;
    var cpu = fresh();
    const future = wide(0x1000, 0xF080, 0xC001); // BFL, boff=1: branch point at 0x1006
    cpu.regs.pc = future.address + 4;
    try (branch_future.group.decode(future) orelse return error.NotDecoded)(&cpu, future);
    try std.testing.expectEqual(@as(u32, 0x1004), cpu.regs.pc);

    // BFL's fallback BL is the four-byte instruction at the branch point.
    const fallback = wide(branch_point, 0xF000, 0xF800);
    cpu.regs.pc = fallback.address + 4;
    try (branch_wide.group.decode(fallback) orelse return error.NotDecoded)(&cpu, fallback);
    try std.testing.expectEqual(branch_point + 4 | 1, cpu.regs.lr);
}

test "BFLX fallback BLX sets LR at its branch point" {
    const branch_point: u32 = 0x2006;
    var cpu = fresh();
    cpu.regs.low[0] = 0x3001;
    const future = wide(0x2000, 0xF0F0, 0xE001); // BFLX with R0, boff=1
    cpu.regs.pc = future.address + 4;
    try (branch_future.group.decode(future) orelse return error.NotDecoded)(&cpu, future);
    try std.testing.expectEqual(@as(u32, 0x2004), cpu.regs.pc);

    // BLX R0 is the two-byte fallback instruction at the branch point.
    const fallback = Instr{ .address = branch_point, .hw1 = 0x4780, .size = 2 };
    cpu.regs.pc = fallback.address + 2;
    try (special_data.group.decode(fallback) orelse return error.NotDecoded)(&cpu, fallback);
    try std.testing.expectEqual(branch_point + 2 | 1, cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0x3000), cpu.regs.pc);
}

test "non-branch-future encodings and zero branch offsets stay unclaimed" {
    const invalid = [_]Instr{
        wide(0, 0xF080, 0xD001),
        wide(0, 0xF000, 0xC001), // zero boff
        wide(0, 0xF0E2, 0xE000), // invalid low encoding bit
        wide(0, 0xF0E2, 0xE009), // invalid register-form reserved bits
        .{ .address = 0, .hw1 = 0xF0C0, .hw2 = 0xE001, .size = 2 },
    };
    for (invalid) |instr| try std.testing.expect(branch_future.group.decode(instr) == null);
}

test "no earlier group claims a Branch Future encoding" {
    const instr = wide(0, forms[0].hw1, forms[0].hw2);
    for (ra8.chip.core.cpu.ops.table.groups) |group| {
        if (group.decode(instr) == null) continue;
        try std.testing.expectEqualStrings("branch_future", group.name);
        return;
    }
    return error.NotDecoded;
}
