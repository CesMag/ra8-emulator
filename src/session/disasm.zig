//! One instruction, in text, for the fault path and the debugger.
//!
//! When a run ends on a fault the PC alone is not much of an answer. Give this
//! the bytes at the PC and it gives back "str r1, [r0]", decoded by the Zig
//! core's own table and printed by its group printers (RA8EMU-17), in the
//! spelling the parity digest tests pin. No C is involved (RA8EMU-249).
const Instr = @import("ra8_chip").core.cpu.instr.Instr;
const printers = @import("ra8_chip").core.cpu.text.disasm;
const text = @import("ra8_chip").core.cpu.text.text;

pub const Error = error{NothingDecoded};

pub const Text = text.Text;

/// Decode the single instruction at `address` from `bytes`: two bytes for a
/// 16-bit encoding, four for a 32-bit one, little-endian halfwords.
pub fn one(address: u32, bytes: []const u8) Error!Text {
    const instr = fromBytes(address, bytes) orelse return Error.NothingDecoded;
    return printers.one(instr) orelse Error.NothingDecoded;
}

fn fromBytes(address: u32, bytes: []const u8) ?Instr {
    if (bytes.len < 2) return null;
    const hw1 = halfword(bytes[0..2]);
    if (!Instr.isWide(hw1)) return .{ .address = address, .hw1 = hw1, .size = 2 };
    if (bytes.len < 4) return null;
    return .{ .address = address, .hw1 = hw1, .hw2 = halfword(bytes[2..4]), .size = 4 };
}

fn halfword(pair: *const [2]u8) u16 {
    return @as(u16, pair[0]) | (@as(u16, pair[1]) << 8);
}
