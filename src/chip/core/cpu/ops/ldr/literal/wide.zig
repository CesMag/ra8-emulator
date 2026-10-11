//! The 32-bit literal loads: LDRB, LDRH, LDR, LDRSB and LDRSH with Rn = PC
//! (T1/T2 literal forms, hw1 = 1111100 S U size 1 1111). The address is
//! Align(PC, 4) +/- imm12, where PC reads as the instruction's address plus 4.
//!
//! LDR with Rt = PC branches with interworking, and LDR with Rt = SP loads SP
//! (RA8EMU-132). A byte or halfword form with Rt = PC is PLD or PLI, which
//! ops/preload.zig claims; one with Rt = SP is UNPREDICTABLE and unclaimed.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const bti = @import("../../../bti.zig");

pub const encodings = struct {
    /// hw1 with S ([8]), U ([7]) and size ([6:5]) masked out: load, Rn = PC.
    pub const mask: u16 = 0xFE1F;
    pub const match: u16 = 0xF81F;
};

pub const group: op.Group = .{ .name = "ldr_literal_wide", .decode = decode };

pub const Form = struct {
    /// Bytes read: 1, 2 or 4.
    size: u3,
    signed: bool,
    rt: u4,
    address: u32,
};

pub fn form(instr: Instr) ?Form {
    if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.match) return null;
    const signed = instr.hw1 & 0x0100 != 0;
    const size: u3 = switch ((instr.hw1 >> 5) & 0x3) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => return null,
    };
    if (signed and size == 4) return null;
    const rt: u4 = @intCast(instr.hw2 >> 12);
    if (rt == 15 and size != 4) return null;
    if (rt == 13 and size != 4) return null;
    const base = (instr.address +% 4) & ~@as(u32, 3);
    const imm: u32 = instr.hw2 & 0x0FFF;
    const add = instr.hw1 & 0x0080 != 0;
    return .{ .size = size, .signed = signed, .rt = rt, .address = if (add) base +% imm else base -% imm };
}

fn decode(instr: Instr) ?op.Exec {
    return if (form(instr) == null) null else load;
}

fn load(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = form(instr).?;
    const value: u32 = switch (f.size) {
        1 => blk: {
            var b: [1]u8 = undefined;
            try cpu.bus.read(f.address, &b);
            break :blk if (f.signed) @bitCast(@as(i32, @as(i8, @bitCast(b[0])))) else b[0];
        },
        2 => blk: {
            const h = try cpu.bus.readHalf(f.address);
            break :blk if (f.signed) @bitCast(@as(i32, @as(i16, @bitCast(h)))) else h;
        },
        else => try cpu.bus.readWord(f.address),
    };
    if (f.rt == 15) {
        cpu.regs.bxWritePc(value);
        if (cpu.regs.exc_return == null) bti.setForAddress(&cpu.regs, cpu.profile.v8_1m);
    } else cpu.regs.set(f.rt, value);
}
