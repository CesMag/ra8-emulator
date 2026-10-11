//! MVE VMOV, VMVN, VORR and VBIC (immediate, T1), predicated by VPR
//! (RA8EMU-633). hw1 is 111i 1111 1 D 000 imm3 and hw2 is Qd 0 cmode 0 1
//! op 1 imm4, with imm8 = i:imm3:imm4. D would name Q8 and above, so it
//! must be zero, and cmode 1111 with op set is UNDEFINED. The semantics
//! are in src/chip/core/cpu/mve/modimm/modimm.zig.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_int = @import("int/int.zig");

pub const group: op.Group = .{ .name = "mve_modimm", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with i (bit 12) and imm3 (2:0) masked out.
    pub const hw1: u16 = 0xEF80;
    pub const hw1_mask: u16 = 0xEFF8;
    /// hw2 with Qd (15:13), cmode (11:8), op (5) and imm4 (3:0) masked out.
    pub const hw2: u16 = 0x0050;
    pub const hw2_mask: u16 = 0x10D0;
};

pub const Fields = struct { qd: u3, op: u1, cmode: u4, imm8: u8 };

/// The fields of an MVE modified-immediate encoding, or null when the
/// encoding is not one (including the UNDEFINED cmode 1111, op 1).
pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const f: Fields = .{
        .qd = @intCast(instr.hw2 >> 13),
        .op = @intCast(instr.hw2 >> 5 & 1),
        .cmode = @intCast(instr.hw2 >> 8 & 0xF),
        .imm8 = @intCast((instr.hw1 >> 12 & 1) << 7 | (instr.hw1 & 7) << 4 | (instr.hw2 & 0xF)),
    };
    _ = mve.modimm.kind(f.op, f.cmode) orelse return null;
    return f;
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const old = mve.qreg.read(&cpu.fp.bank, f.qd);
    mve_int.writePredicated(cpu, f.qd, mve.modimm.run(f.op, f.cmode, f.imm8, old).?);
}
