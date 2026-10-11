//! ADDW and SUBW with a plain 12-bit immediate (ADD T4, SUB T4), plus their
//! Rn = PC forms, ADR T3 and T2. imm12 is i:imm3:imm8, never rotated, and
//! none of them touch the flags. ADR adds to the word-aligned PC.
//!
//! Rd of PC is UNPREDICTABLE, and Rd of SP is only legal when Rn is SP;
//! both are left unclaimed.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with i ([10]) and Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFBF0;
    pub const addw: u16 = 0xF200;
    pub const subw: u16 = 0xF2A0;
    /// hw2[15] is zero in both.
    pub const hw2_zero: u16 = 0x8000;
};

pub const group: op.Group = .{ .name = "add_sub_wide", .decode = decode };

pub const Fields = struct {
    sub: bool,
    rn: u4,
    rd: u4,
    imm12: u32,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
        const sub = switch (instr.hw1 & encodings.mask) {
            encodings.addw => false,
            encodings.subw => true,
            else => return null,
        };
        const i: u32 = (instr.hw1 >> 10) & 0x1;
        const imm3: u32 = (instr.hw2 >> 12) & 0x7;
        return .{
            .sub = sub,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .imm12 = (i << 11) | (imm3 << 8) | (instr.hw2 & 0xFF),
        };
    }
};

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (f.rd == 15) return null;
    if (f.rd == 13 and f.rn != 13) return null;
    return exec;
}

/// The base value: Align(PC, 4) for ADR, Rn otherwise.
fn base(cpu: *Cpu, instr: Instr, rn: u4) u32 {
    if (rn == 15) return (instr.address +% 4) & ~@as(u32, 3);
    return cpu.regs.get(rn);
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const b = base(cpu, instr, f.rn);
    cpu.regs.set(f.rd, if (f.sub) b -% f.imm12 else b +% f.imm12);
}
