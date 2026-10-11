//! MVE VQDMLAH, VQRDMLAH, VQDMLASH and VQRDMLASH (vector by scalar, T1),
//! predicated by VPR (RA8EMU-25). Per LLVM's assembler and QEMU's
//! mve.decode: hw1 1110 1110 0 D size Qn 0 and hw2 Qda S 1110 N 1 R' 0 Rm,
//! S selecting the ASH (scalar addend) forms and bits 6:4 100 for the
//! rounding forms, 110 for the plain ones. Qda is read and written, and
//! FPSCR.QC is set only from lanes the VPT block leaves active. Size 11, D
//! or N set (Q8+), and Rm of SP or PC stay unclaimed. Lane semantics are in
//! src/chip/core/cpu/mve/int/mul/mul.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("int.zig");
const pair = @import("pair.zig");
const Size = mve.qreg.Size;
const DoublingForm = mve.int.mul.DoublingForm;

pub const group: op.Group = .{ .name = "mve_int_vqdmlah", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with size (5:4) and Qn (3:1) masked out; U, D and bit 0 clear.
    pub const hw1_mask: u16 = 0xFFC1;
    pub const hw1: u16 = 0xEE00;
    /// hw2 with Qda (15:13) and Rm (3:0) masked out.
    pub const hw2_mask: u16 = 0x1FF0;
    pub const vqrdmlah: u16 = 0x0E40;
    pub const vqrdmlash: u16 = 0x1E40;
    pub const vqdmlah: u16 = 0x0E60;
    pub const vqdmlash: u16 = 0x1E60;
};

/// The form an encoding names, or null when this group does not claim it.
pub fn formOf(instr: Instr) ?DoublingForm {
    const e = encodings;
    return switch (instr.hw2 & e.hw2_mask) {
        e.vqrdmlah => .{ .round = true },
        e.vqrdmlash => .{ .scalar_addend = true, .round = true },
        e.vqdmlah => .{},
        e.vqdmlash => .{ .scalar_addend = true },
        else => null,
    };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    const size = instr.hw1 >> 4 & 3;
    if (size == 3) return null;
    const rm = instr.hw2 & 0xF;
    if (rm == 13 or rm == 15) return null;
    _ = formOf(instr) orelse return null;
    return switch (size) {
        0 => execFor(.byte),
        1 => execFor(.half),
        else => execFor(.word),
    };
}

fn execFor(comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const form = formOf(instr).?;
            const qda: u3 = @intCast(instr.hw2 >> 13);
            const qn: u3 = @intCast(instr.hw1 >> 1 & 7);
            const scalar = cpu.regs.get(@intCast(instr.hw2 & 0xF));
            const da = mve.qreg.read(&cpu.fp.bank, qda);
            const n = mve.qreg.read(&cpu.fp.bank, qn);
            const result = mve.int.mul.doublingMultiplyAccumulateHigh(da, n, scalar, size, form);
            const live = pair.activeLanes(mve_beats.mask(cpu), size);
            if (mve.int.mul.doublingMultiplyAccumulateHigh(da & live, n & live, scalar, size, form).saturated) cpu.fp.fpscr.qc = 1;
            mve_int.writePredicated(cpu, qda, result.value);
        }
    }.exec;
}
