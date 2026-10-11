//! SXTH, SXTB, UXTH and UXTB (T1): Rd = Rm with its low halfword or byte
//! sign- or zero-extended. The 16-bit forms take no rotation and set no
//! flags.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
pub const b16 = @import("b16.zig");
pub const wide = @import("wide.zig");

pub const encodings = struct {
    pub const mask: u16 = 0xFF00;
    pub const extend: u16 = 0xB200;
};

pub const Kind = enum(u2) { sxth, sxtb, uxth, uxtb };

pub const group: op.Group = .{ .name = "extend", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.extend) return null;
    return run;
}

/// `value` extended the way `kind` says.
pub fn apply(kind: Kind, value: u32) u32 {
    return switch (kind) {
        .sxth => @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(value)))))),
        .sxtb => @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(value)))))),
        .uxth => value & 0xFFFF,
        .uxtb => value & 0xFF,
    };
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const kind: Kind = @fromBackingInt(@intCast((instr.hw1 >> 6) & 3));
    const rm: u4 = @intCast((instr.hw1 >> 3) & 7);
    const rd: u4 = @intCast(instr.hw1 & 7);
    cpu.regs.set(rd, apply(kind, cpu.regs.get(rm)));
}
