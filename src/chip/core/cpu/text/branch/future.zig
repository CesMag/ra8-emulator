//! Text for the branch_future group (Armv8.1-M), in Arm ARM syntax with
//! absolute addresses: `bf #point, #target`, `bfl #point, #target`, `bfx
//! #point, rn`, `bflx #point, rn` and `bfcsel #point, #target, #after, cond`.
//! The branch point is the next instruction plus boff (hw1[10:7]) halfwords.
//! The target offset is immA:immB:immC:'0' sign-extended, immA being
//! hw1[4:0] for BF, hw1[6:0] for BFL and hw1[0] for BFCSEL; immB is
//! hw2[10:1] and immC hw2[11]. BFCSEL's else address is the branch point
//! plus 4 when hw1[1] (T) is set, else plus 2.
const Instr = @import("../../instr.zig").Instr;
const ops = @import("../../ops/branch/future.zig");
const text = @import("../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    const next = instr.address +% 4;
    const point = next +% ((hw1 & ops.encodings.boff_mask) >> 7) * 2;
    const low: u32 = ((instr.hw2 & 0x07FE) << 1) | (((instr.hw2 >> 11) & 1) << 1);
    if (instr.hw2 & 0xF000 == ops.encodings.bfl_hw2) {
        return labelled(out, "bfl", point, next, signExtend(@as(u32, hw1 & 0x7F) << 12 | low, 19));
    }
    if (hw1 & 0x0060 == 0x0060) {
        out.put("{s} ", .{if (hw1 & 0x0010 != 0) "bflx" else "bfx"});
        out.imm(point);
        return out.put(", {s}", .{text.names[hw1 & 0xF]});
    }
    if (hw1 & 0x0040 != 0) {
        return labelled(out, "bf", point, next, signExtend(@as(u32, hw1 & 0x1F) << 12 | low, 17));
    }
    labelled(out, "bfcsel", point, next, signExtend(@as(u32, hw1 & 1) << 12 | low, 13));
    out.put(", ", .{});
    out.imm(point +% @as(u32, if (hw1 & 0x0002 != 0) 4 else 2));
    const cond = (hw1 >> 2) & 0xF;
    out.put(", {s}", .{if (cond < text.conds.len) text.conds[cond] else "nv"});
}

fn labelled(out: *text.Text, mnemonic: []const u8, point: u32, next: u32, offset: i32) void {
    out.put("{s} ", .{mnemonic});
    out.imm(point);
    out.put(", ", .{});
    out.imm(next +% @as(u32, @bitCast(offset)));
}

fn signExtend(value: u32, comptime bits: u6) i32 {
    const shift: u5 = @intCast(32 - bits);
    return @as(i32, @bitCast(value << shift)) >> shift;
}
