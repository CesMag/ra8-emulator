//! Text for the ldst_imm group: STR/LDR, STRB/LDRB and STRH/LDRH with a
//! five-bit immediate, and STR/LDR relative to SP with an eight-bit one.
//! An offset of zero prints as `[rn]`.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");

const sp: u4 = 13;

/// By bits [15:11] minus 0b01100: word, byte, half, then SP-relative.
const forms = [8]struct { mnemonic: []const u8, scale: u5 }{
    .{ .mnemonic = "str", .scale = 2 },  .{ .mnemonic = "ldr", .scale = 2 },
    .{ .mnemonic = "strb", .scale = 0 }, .{ .mnemonic = "ldrb", .scale = 0 },
    .{ .mnemonic = "strh", .scale = 1 }, .{ .mnemonic = "ldrh", .scale = 1 },
    .{ .mnemonic = "str", .scale = 2 },  .{ .mnemonic = "ldr", .scale = 2 },
};

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    const index = (hw1 >> 11) - 0b01100;
    const form = forms[index];
    const sp_relative = index >= 6;
    const rt = if (sp_relative) text.low(hw1, 8) else text.low(hw1, 0);
    const rn = if (sp_relative) sp else text.low(hw1, 3);
    const field: u32 = if (sp_relative) hw1 & 0xFF else (hw1 >> 6) & 0x1F;
    out.put("{s} {s}, [{s}", .{ form.mnemonic, text.names[rt], text.names[rn] });
    if (field != 0) {
        out.put(", ", .{});
        out.imm(field << form.scale);
    }
    out.put("]", .{});
}
