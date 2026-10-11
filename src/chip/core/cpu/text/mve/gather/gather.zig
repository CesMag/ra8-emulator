//! Text for MVE register-offset gather/scatter, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/gather/gather.zig");
const gather = @import("../../../mve/gather/gather.zig");
const Size = @import("../../../mve/qreg.zig").Size;
const text = @import("../../text.zig");

fn width(size: Size) []const u8 {
    return switch (size) {
        .byte => "8",
        .half => "16",
        .word => "32",
    };
}

fn letter(size: Size) []const u8 {
    return switch (size) {
        .byte => "b",
        .half => "h",
        .word => "w",
    };
}

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.formOf(instr) orelse return;
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const qm: u3 = @intCast(instr.hw2 >> 1 & 7);
    const rn = text.names[instr.hw1 & 15];
    const root = if (f.store) "vstr" else "vldr";
    const os = if (!f.os) "" else switch (f.msize) {
        .byte => "",
        .half => ", uxtw #1",
        .word => ", uxtw #2",
    };
    if (f.store) {
        out.put("{s}{s}{s}.{s} q{d}, [{s}, q{d}{s}]", .{ root, letter(f.msize), suffix, width(f.msize), qd, rn, qm, os });
    } else {
        const sign = if (f.signed) "s" else "u";
        out.put("{s}{s}{s}.{s}{s} q{d}, [{s}, q{d}{s}]", .{ root, letter(f.msize), suffix, sign, width(f.esize), qd, rn, qm, os });
    }
}
