//! MVE VQADD and VQSUB (vector) and the pairwise group VHADD, VRHADD,
//! VHSUB, VMAX, VMIN and VABD (vector), all T1, predicated by VPR
//! (RA8EMU-25). hw1 is 111U 1111 0 D size Qn 0, U selecting unsigned, and
//! hw2 is Qd 0 opc N 1 M x Qm 0. The opc:x pairs from LLVM's assembler are
//! below. VQADD and VQSUB set FPSCR.QC when an active lane saturates;
//! lanes the VPT block masks off neither change nor raise QC. The lane
//! semantics are in src/chip/core/cpu/mve/int/int.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("int.zig");
const Size = mve.qreg.Size;
const Pairwise = mve.int.Pairwise;

pub const group: op.Group = .{ .name = "mve_int_pair", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw2 with Qd (15:13) and Qm (3:1) masked out, as mve_int.encodings.
    pub const vqadd: u16 = 0x0050;
    pub const vqsub: u16 = 0x0250;
    pub const vhadd: u16 = 0x0040;
    pub const vrhadd: u16 = 0x0140;
    pub const vhsub: u16 = 0x0240;
    pub const vmax: u16 = 0x0640;
    pub const vmin: u16 = 0x0650;
    pub const vabd: u16 = 0x0740;
};

const Kind = enum { vqadd, vqsub, vhadd, vrhadd, vhsub, vmax, vmin, vabd };

fn kindOf(tail: u16) ?Kind {
    const info = @typeInfo(Kind).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (tail == @field(encodings, name)) return @fromBackingInt(@intCast(value));
    }
    return null;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & mve_int.encodings.hw1_mask != mve_int.encodings.hw1) return null;
    const size = instr.hw1 >> 4 & 3;
    if (size == 3) return null;
    const kind = kindOf(instr.hw2 & mve_int.encodings.hw2_mask) orelse return null;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    return switch (kind) {
        inline else => |k| switch (size) {
            0 => if (unsigned) execFor(k, .byte, true) else execFor(k, .byte, false),
            1 => if (unsigned) execFor(k, .half, true) else execFor(k, .half, false),
            else => if (unsigned) execFor(k, .word, true) else execFor(k, .word, false),
        },
    };
}

fn pairOf(comptime kind: Kind) Pairwise {
    return switch (kind) {
        .vhadd => .hadd,
        .vrhadd => .rhadd,
        .vhsub => .hsub,
        .vmax => .max,
        .vmin => .min,
        .vabd => .abd,
        else => unreachable,
    };
}

fn execFor(comptime kind: Kind, comptime size: Size, comptime unsigned: bool) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = mve_int.regs(instr);
            const a = mve.qreg.read(&cpu.fp.bank, r[1]);
            const b = mve.qreg.read(&cpu.fp.bank, r[2]);
            const result = switch (kind) {
                .vqadd, .vqsub => saturate(cpu, a, b, size, unsigned, kind == .vqsub),
                else => mve.int.pairwise(a, b, size, unsigned, comptime pairOf(kind)),
            };
            mve_int.writePredicated(cpu, r[0], result);
        }
    }.exec;
}

/// VQADD or VQSUB; QC is raised only by a lane the VPT block leaves active.
fn saturate(cpu: *Cpu, a: u128, b: u128, size: Size, unsigned: bool, sub: bool) u128 {
    const live = activeLanes(mve_beats.mask(cpu), size);
    if (mve.int.saturating(a & live, b & live, size, unsigned, sub).saturated) cpu.fp.fpscr.qc = 1;
    return mve.int.saturating(a, b, size, unsigned, sub).value;
}

/// All ones over each element whose lowest byte the mask enables.
pub fn activeLanes(mask: u16, size: Size) u128 {
    var out: u128 = 0;
    for (0..mve.qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        if (mve.predicate.active(mask, size, e)) out = mve.qreg.setElem(out, size, e, 0xFFFF_FFFF);
    }
    return out;
}
