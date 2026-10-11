//! Text for the dp_shifted group: the 32-bit data processing forms with a
//! shifted register, and their aliases TST, TEQ, CMN and CMP (Rd of PC with
//! S set), MOV/LSL/LSR/ASR/ROR/RRX (ORR with Rn of PC) and MVN (ORN with Rn
//! of PC). We write `.w` on everything but ORN, RSB and RRX, which
//! have no 16-bit twin. The shift suffix is decimal; the shift aliases print
//! their amount as an ordinary immediate.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const dp = @import("../../ops/dp/shifted.zig");

const opcodes = dp.opcodes;
const kinds = [4][]const u8{ "lsl", "lsr", "asr", "ror" };

pub fn print(instr: Instr, out: *text.Text) void {
    const f = dp.Fields.of(instr).?;
    const s: []const u8 = if (f.s) "s" else "";
    if (compare(f)) |name| {
        out.put("{s}.w {s}, {s}", .{ name, text.names[f.rn], text.names[f.rm] });
        return suffix(f, out);
    }
    if (f.rn == 15 and f.opcode == opcodes.orr) return move(f, s, out);
    if (f.rn == 15 and f.opcode == opcodes.orn) {
        out.put("mvn{s}.w {s}, {s}", .{ s, text.names[f.rd], text.names[f.rm] });
        return suffix(f, out);
    }
    const wide: []const u8 = if (f.opcode == opcodes.orn or f.opcode == opcodes.rsb) "" else ".w";
    out.put("{s}{s}{s} {s}, {s}, {s}", .{ mnemonic(f.opcode), s, wide, text.names[f.rd], text.names[f.rn], text.names[f.rm] });
    suffix(f, out);
}

fn compare(f: dp.Fields) ?[]const u8 {
    if (f.rd != 15 or !f.s) return null;
    return switch (f.opcode) {
        opcodes.and_ => "tst",
        opcodes.eor => "teq",
        opcodes.add => "cmn",
        opcodes.sub => "cmp",
        else => null,
    };
}

fn move(f: dp.Fields, s: []const u8, out: *text.Text) void {
    if (f.kind == .lsl and f.imm5 == 0) {
        return out.put("mov{s}.w {s}, {s}", .{ s, text.names[f.rd], text.names[f.rm] });
    }
    if (f.kind == .ror and f.imm5 == 0) {
        return out.put("rrx{s} {s}, {s}", .{ s, text.names[f.rd], text.names[f.rm] });
    }
    out.put("{s}{s}.w {s}, {s}, ", .{ kinds[@backingInt(f.kind)], s, text.names[f.rd], text.names[f.rm] });
    out.imm(amount(f));
}

fn suffix(f: dp.Fields, out: *text.Text) void {
    if (f.kind == .lsl and f.imm5 == 0) return;
    if (f.kind == .ror and f.imm5 == 0) return out.put(", rrx", .{});
    out.put(", {s} #{d}", .{ kinds[@backingInt(f.kind)], amount(f) });
}

/// LSR and ASR encode a shift of 32 as zero.
fn amount(f: dp.Fields) u32 {
    return if (f.imm5 == 0) 32 else f.imm5;
}

fn mnemonic(opcode: u4) []const u8 {
    return switch (opcode) {
        opcodes.and_ => "and",
        opcodes.bic => "bic",
        opcodes.orr => "orr",
        opcodes.orn => "orn",
        opcodes.eor => "eor",
        opcodes.add => "add",
        opcodes.adc => "adc",
        opcodes.sbc => "sbc",
        opcodes.sub => "sub",
        else => "rsb",
    };
}
