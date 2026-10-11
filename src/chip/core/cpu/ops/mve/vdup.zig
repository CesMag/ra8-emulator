//! MVE VDUP (T1): every element of Qd set to the low bits of Rt
//! (RA8EMU-25). The encoding is 1110 1110 1 B 1 0 Qd 0 then Rt 1011 0 0 E 1
//! 0000, with B:E picking the size (00 word, 01 half, 10 byte, 11 undefined),
//! per LLVM's assembler and the Arm ARM (DDI0553). VDUP is predicated
//! element-wise, so it writes through the VPT element mask and advances the
//! block. Rt of 13 or 15 is UNPREDICTABLE and left unclaimed.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_int = @import("int/int.zig");
const scalar = @import("int/scalar.zig");
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_vdup", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xFFB1;
    pub const hw1: u16 = 0xEEA0;
    pub const hw2_mask: u16 = 0x0FDF;
    pub const hw2: u16 = 0x0B10;
};

/// The element size B:E selects, or null for the undefined 11.
pub fn sizeOf(instr: Instr) ?Size {
    const b = instr.hw1 >> 6 & 1;
    const e = instr.hw2 >> 5 & 1;
    return switch (b << 1 | e) {
        0b00 => .word,
        0b01 => .half,
        0b10 => .byte,
        else => null,
    };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const rt = instr.hw2 >> 12;
    if (rt == 13 or rt == 15) return null;
    const size = sizeOf(instr) orelse return null;
    return switch (size) {
        .byte => execFor(.byte),
        .half => execFor(.half),
        .word => execFor(.word),
    };
}

fn execFor(comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const qd: u3 = @intCast(instr.hw1 >> 1 & 7);
            const value = scalar.splat(cpu.regs.get(@intCast(instr.hw2 >> 12)), size);
            mve_int.writePredicated(cpu, qd, value);
        }
    }.exec;
}
