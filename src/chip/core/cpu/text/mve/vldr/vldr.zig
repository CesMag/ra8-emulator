//! Text for MVE contiguous element-sized loads/stores, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/vldr/vldr.zig");
const text = @import("../../text.zig");

fn suffix(size: @import("../../../mve/qreg.zig").Size) []const u8 {
    return switch (size) {
        .byte => "b",
        .half => "h",
        .word => "w",
    };
}

fn width(size: @import("../../../mve/qreg.zig").Size) []const u8 {
    return switch (size) {
        .byte => "8",
        .half => "16",
        .word => "32",
    };
}

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, pred: []const u8) void {
    const size = ops.sizeOf(instr) orelse return;
    const load = instr.hw1 >> 4 & 1 == 1;
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const rn = text.names[instr.hw1 & 15];
    const root = if (load) "vldr" else "vstr";
    const dtype = if (load) (if (size == .byte) ".u8" else if (size == .half) ".u16" else ".u32") else if (size == .byte) ".8" else if (size == .half) ".16" else ".32";
    const imm: u32 = @as(u32, @intCast(instr.hw2 & 0x7f)) * (@as(u32, 1) << @intCast(@backingInt(size)));
    const add = instr.hw1 >> 7 & 1 == 1;
    const pre = instr.hw1 >> 8 & 1 == 1;
    const writeback = instr.hw1 >> 5 & 1 == 1;
    out.put("{s}{s}{s}{s} q{d}, [{s}", .{ root, suffix(size), pred, dtype, qd, rn });
    if (pre and imm != 0) {
        out.put(", ", .{});
        putOffset(out, imm, add);
    }
    out.put("]{s}", .{if (pre and writeback) "!" else ""});
    if (!pre) {
        out.put(", ", .{});
        putOffset(out, imm, add);
    }
}

fn putOffset(out: *text.Text, magnitude: u32, add: bool) void {
    const bits: u32 = if (add) magnitude else 0 -% magnitude;
    out.signedImm(bits);
}
