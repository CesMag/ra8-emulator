//! MVE VCVT between float and fixed-point lanes (T1), predicated by VPR
//! (RA8EMU-23). hw1 is 111U 1111 1 D imm6 and hw2 is Qd 0 11 s op 0 1 M 1
//! Qm 0, per QEMU's mve.decode and LLVM's assembler. s=1 pairs F32 with
//! 32-bit fixed point and needs imm6<5> set, fbits = 32 - imm6<4:0>; s=0
//! pairs F16 with 16-bit fixed point and needs imm6<5:4> = 11, fbits = 16 -
//! imm6<3:0>. op=0 converts fixed to float (round to nearest), op=1 float
//! to fixed (toward zero), and U picks unsigned. D and M would name Q8 and
//! above, so they must be zero. The lane semantics are in
//! src/chip/core/cpu/mve/float/int/int.zig.
const op = @import("../../../../op.zig");
const Cpu = @import("../../../../cpu.zig").Cpu;
const Instr = @import("../../../../instr.zig").Instr;
const mve = @import("../../../../mve/all.zig");
const mve_beats = @import("../../beats.zig");

pub const group: op.Group = .{ .name = "mve_float_cvt_fixed", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// F32: hw1 with U (12) and imm6<4:0> masked out.
    pub const word_hw1: u16 = 0xEFA0;
    pub const word_hw1_mask: u16 = 0xEFE0;
    /// F16: hw1 with U (12) and imm6<3:0> masked out.
    pub const half_hw1: u16 = 0xEFB0;
    pub const half_hw1_mask: u16 = 0xEFF0;
    /// hw2 with Qd, s (9), op (8) and Qm masked out.
    pub const hw2: u16 = 0x0C50;
    pub const hw2_mask: u16 = 0x1CF1;
    pub const word_bit: u16 = 0x0200;
};

/// The fields one encoding names.
pub const Fields = struct { qd: u3, qm: u3, size: mve.float.Size, unsigned: bool, to_fixed: bool, fbits: u6 };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const word = instr.hw2 & encodings.word_bit != 0;
    const fbits: u6 = if (word) blk: {
        if (instr.hw1 & encodings.word_hw1_mask != encodings.word_hw1) return null;
        break :blk @intCast(32 - (instr.hw1 & 0x1F));
    } else blk: {
        if (instr.hw1 & encodings.half_hw1_mask != encodings.half_hw1) return null;
        break :blk @intCast(16 - (instr.hw1 & 0xF));
    };
    return .{
        .qd = @intCast(instr.hw2 >> 13 & 7),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .size = if (word) .word else .half,
        .unsigned = instr.hw1 >> 12 & 1 == 1,
        .to_fixed = instr.hw2 >> 8 & 1 == 1,
        .fbits = fbits,
    };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const bank = &cpu.fp.bank;
    const old = mve.qreg.read(bank, f.qd);
    const m = mve.qreg.read(bank, f.qm);
    const mask = mve_beats.mask(cpu);
    const fpscr = &cpu.fp.fpscr;
    const result = if (f.to_fixed)
        mve.float.int.toInt(old, m, f.size, f.unsigned, .zero, f.fbits, mask, fpscr)
    else
        mve.float.int.fromInt(old, m, f.size, f.unsigned, f.fbits, mask, fpscr);
    mve.qreg.write(bank, f.qd, result);
    mve_beats.finish(cpu);
}
