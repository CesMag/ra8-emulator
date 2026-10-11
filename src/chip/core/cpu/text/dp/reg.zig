//! Text for the dp_reg group: the sixteen two-register data-processing
//! opcodes. RSBS prints its implied #0 and MULS repeats Rd at the end, as
//! UAL disassemblers conventionally do.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");

const mnemonics = [16][]const u8{
    "ands", "eors", "lsls", "lsrs", "asrs", "adcs", "sbcs", "rors",
    "tst",  "rsbs", "cmp",  "cmn",  "orrs", "muls", "bics", "mvns",
};

const rsb: u16 = 0x9;
const mul: u16 = 0xD;

pub fn print(instr: Instr, out: *text.Text) void {
    const opcode = (instr.hw1 >> 6) & 0xF;
    const rm = text.low(instr.hw1, 3);
    const rd = text.low(instr.hw1, 0);
    switch (opcode) {
        rsb => out.put("rsbs {s}, {s}, #0", .{ text.names[rd], text.names[rm] }),
        mul => out.regs3("muls", rd, rm, rd),
        else => out.regs2(mnemonics[opcode], rd, rm),
    }
}
