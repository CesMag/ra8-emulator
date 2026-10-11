//! MVE VMLA and VMLAS (vector by scalar, T1), predicated by VPR
//! (RA8EMU-25). hw1 is 111U 1110 0 D size Qn 1 (as VMULH) and hw2 is
//! Qda S 1 1 1 0 N 1 M 0 Rm, S selecting VMLAS, per LLVM's assembler, which
//! always writes U as 0; the result is modulo the lane width, so U changes
//! nothing. Qda is read and written. Rm of SP or PC is CONSTRAINED
//! UNPREDICTABLE and left unclaimed. Lane semantics are in
//! src/chip/core/cpu/mve/int/mul/mul.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_int = @import("int.zig");
const mulh = @import("mulh.zig");
const Size = mve.qreg.Size;
const ScalarForm = mve.int.mul.ScalarForm;

pub const group: op.Group = .{ .name = "mve_int_vmla", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw2 with Qda (15:13) and Rm (3:0) masked out.
    pub const hw2_mask: u16 = 0x1FF0;
    pub const vmla: u16 = 0x0E40;
    pub const vmlas: u16 = 0x1E40;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & mve_int.encodings.hw1_mask != mulh.encodings.mulh_hw1) return null;
    const size = instr.hw1 >> 4 & 3;
    if (size == 3) return null;
    const rm = instr.hw2 & 0xF;
    if (rm == 13 or rm == 15) return null;
    const tail = instr.hw2 & encodings.hw2_mask;
    const form: ScalarForm = if (tail == encodings.vmla) .vmla else if (tail == encodings.vmlas) .vmlas else return null;
    return switch (form) {
        inline else => |f| switch (size) {
            0 => execFor(.byte, f),
            1 => execFor(.half, f),
            else => execFor(.word, f),
        },
    };
}

fn execFor(comptime size: Size, comptime form: ScalarForm) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const qda: u3 = @intCast(instr.hw2 >> 13);
            const qn: u3 = @intCast(instr.hw1 >> 1 & 7);
            const scalar = cpu.regs.get(@intCast(instr.hw2 & 0xF));
            const da = mve.qreg.read(&cpu.fp.bank, qda);
            const n = mve.qreg.read(&cpu.fp.bank, qn);
            mve_int.writePredicated(cpu, qda, mve.int.mul.multiplyAddScalar(da, n, scalar, size, form));
        }
    }.exec;
}
