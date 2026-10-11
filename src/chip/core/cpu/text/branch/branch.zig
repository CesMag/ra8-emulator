//! Text for the branch group, 16-bit: B<cond> with an eight-bit offset and B
//! with an eleven-bit one, printed as the absolute target.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    if (hw1 & 0xF000 == 0xD000) {
        const imm8: i8 = @bitCast(@as(u8, @truncate(hw1)));
        out.put("b{s} ", .{text.conds[(hw1 >> 8) & 0xF]});
        return out.target(instr.address, @as(i32, imm8) * 2);
    }
    const imm11: i11 = @bitCast(@as(u11, @truncate(hw1)));
    out.put("b ", .{});
    out.target(instr.address, @as(i32, imm11) * 2);
}
