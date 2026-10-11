//! The fields of a 32-bit data processing (modified immediate) encoding:
//! hw1 is 11110 i 0 op S Rn, hw2 is 0 imm3 Rd imm8.
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with i, op, S and Rn masked out.
    pub const mask: u16 = 0xFA00;
    pub const value: u16 = 0xF000;
    /// hw2[15] is zero.
    pub const hw2_zero: u16 = 0x8000;
};

pub const Fields = struct {
    opcode: u4,
    s: bool,
    rn: u4,
    rd: u4,

    /// Null when the encoding is not in the modified immediate class.
    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4) return null;
        if (instr.hw1 & encodings.mask != encodings.value) return null;
        if (instr.hw2 & encodings.hw2_zero != 0) return null;
        return .{
            .opcode = @intCast((instr.hw1 >> 5) & 0xF),
            .s = instr.hw1 & 0x10 != 0,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
        };
    }

    pub fn rdIsSpOrPc(self: Fields) bool {
        return self.rd == 13 or self.rd == 15;
    }

    pub fn rnIsSpOrPc(self: Fields) bool {
        return self.rn == 13 or self.rn == 15;
    }
};
