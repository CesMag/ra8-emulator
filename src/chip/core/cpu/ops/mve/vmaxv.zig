//! MVE VMAXV, VMINV, VMAXAV and VMINAV (T1) into the decoder (RA8EMU-25).
//! Per LLVM's assembler and QEMU's mve.decode: hw1 111U 1110 1110 size op
//! with op 10 for VMAXV/VMINV and 00 for VMAXAV/VMINAV (U clear only);
//! hw2 Rda 1111 min 0 M 0 Qm 0. Size 11 is the floating-point VMAXNMV
//! family and stays unclaimed, as do M set and Rda of 13 or 15
//! (UNPREDICTABLE). The fold reads the VPT element mask and the instruction
//! advances the block.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_beats = @import("beats.zig");
const Size = mve.qreg.Size;
const Form = mve.reduce.minmax.Form;

pub const group: op.Group = .{ .name = "mve_vmaxv", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// U, size and op masked out.
    pub const hw1_mask: u16 = 0xEFF0;
    pub const hw1: u16 = 0xEEE0;
    /// Rda, the min bit and Qm masked out; M must be clear.
    pub const hw2_mask: u16 = 0x0F71;
    pub const hw2: u16 = 0x0F00;
};

pub const Fields = struct { size: Size, form: Form };

/// The size and form an encoding names, or null when this group does not
/// claim it.
pub fn fieldsOf(instr: Instr) ?Fields {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const rda = instr.hw2 >> 12;
    if (rda == 13 or rda == 15) return null;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    const size: Size = switch (instr.hw1 >> 2 & 3) {
        0 => .byte,
        1 => .half,
        2 => .word,
        else => return null,
    };
    const abs = switch (instr.hw1 & 3) {
        0b10 => false,
        0b00 => true,
        else => return null,
    };
    if (abs and unsigned) return null;
    const kind: mve.reduce.minmax.Kind = if (instr.hw2 >> 7 & 1 == 1) .min else .max;
    return .{ .size = size, .form = .{ .kind = kind, .unsigned = unsigned, .abs = abs } };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fieldsOf(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fieldsOf(instr).?;
    const rda: u4 = @intCast(instr.hw2 >> 12);
    const qm = mve.qreg.read(&cpu.fp.bank, @intCast(instr.hw2 >> 1 & 7));
    const mask = mve_beats.mask(cpu);
    cpu.regs.set(rda, mve.reduce.minmax.maxminv(cpu.regs.get(rda), qm, f.size, mask, f.form));
    mve_beats.finish(cpu);
}
