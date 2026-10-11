//! MVE VSHL, VRSHL, VQSHL and VQRSHL (register, T1), predicated by VPR
//! (RA8EMU-25). hw1 is 111U 1111 0 D size Qn 0, U selecting unsigned, and
//! hw2 is Qd 0 0 1 0 R N 1 M Q Qm 0 with R for rounding and Q for
//! saturating, per LLVM's assembler. The syntax is VSHL Qd, Qm, Qn: Qm
//! (hw2[3:1]) holds the values and Qn (hw1[3:1]) the per-lane shifts. The
//! saturating forms raise FPSCR.QC only from lanes the VPT block leaves
//! active. The lane semantics are in src/chip/core/cpu/mve/int/shift/shift.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("int.zig");
const pair = @import("pair.zig");
const Size = mve.qreg.Size;
const Mode = mve.int.shift.Mode;

pub const group: op.Group = .{ .name = "mve_int_shift", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw2 with Qd (15:13) and Qm (3:1) masked out, as mve_int.encodings.
    pub const vshl: u16 = 0x0440;
    pub const vrshl: u16 = 0x0540;
    pub const vqshl: u16 = 0x0450;
    pub const vqrshl: u16 = 0x0550;
    /// The R (rounding) and Q (saturating) bits of hw2.
    pub const round_bit: u16 = 0x0100;
    pub const saturate_bit: u16 = 0x0010;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & mve_int.encodings.hw1_mask != mve_int.encodings.hw1) return null;
    const size = instr.hw1 >> 4 & 3;
    if (size == 3) return null;
    const tail = instr.hw2 & mve_int.encodings.hw2_mask;
    if (tail & ~(encodings.round_bit | encodings.saturate_bit) != encodings.vshl) return null;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    const round = tail & encodings.round_bit != 0;
    const saturate = tail & encodings.saturate_bit != 0;
    const key = @as(u3, @intFromBool(unsigned)) << 2 | @as(u3, @intFromBool(round)) << 1 | @intFromBool(saturate);
    return switch (key) {
        inline else => |k| switch (size) {
            0 => execFor(.byte, comptime modeOf(k)),
            1 => execFor(.half, comptime modeOf(k)),
            else => execFor(.word, comptime modeOf(k)),
        },
    };
}

fn modeOf(key: u3) Mode {
    return .{ .unsigned = key & 4 != 0, .round = key & 2 != 0, .saturate = key & 1 != 0 };
}

fn execFor(comptime size: Size, comptime mode: Mode) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = mve_int.regs(instr);
            const values = mve.qreg.read(&cpu.fp.bank, r[2]);
            const shifts = mve.qreg.read(&cpu.fp.bank, r[1]);
            const result = mve.int.shift.byRegister(values, shifts, size, mode);
            if (mode.saturate) {
                const live = pair.activeLanes(mve_beats.mask(cpu), size);
                if (mve.int.shift.byRegister(values & live, shifts, size, mode).saturated) cpu.fp.fpscr.qc = 1;
            }
            mve_int.writePredicated(cpu, r[0], result.value);
        }
    }.exec;
}
