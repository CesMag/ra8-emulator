//! Wire types and row packer for authoritative backend disassembly RPC.
const std = @import("std");
const proto = @import("rpc.zig");

pub const disasm_max_rows: usize = 64;
pub const disasm_text_cap: usize = 96;
pub const disasm_sym_cap: usize = 48;
/// Widest row encoding: 4 (addr) + 1 (size) + 1 (decoded) + 4 (raw) + 1 + text + 1 + sym.
pub const disasm_row_bytes: usize = 4 + 1 + 1 + 4 + 1 + disasm_text_cap + 1 + disasm_sym_cap;
pub const disasm_bytes: usize = disasm_max_rows * disasm_row_bytes;

pub const DisasmAsk = struct {
    core: proto.Core,
    address: u32 = 0,
    count: u8 = 24,
    /// When 1, start from the core's current PC (ignoring `address`).
    use_pc: u8 = 0,
};

pub const DisasmReply = struct {
    core: proto.Core,
    pc: u32,
    count: u8,
    rows: []const u8,
    pub const max_len = .{ .rows = disasm_bytes };
};

pub const DisasmRow = struct {
    address: u32,
    size: u8,
    decoded: u8,
    raw: [4]u8 = .{ 0, 0, 0, 0 },
    text: []const u8 = "",
    symbol: []const u8 = "",
};

pub const Error = error{ Oversize, Truncated };

pub fn put(out: []u8, at: *usize, row: DisasmRow) Error!void {
    const tlen = @min(row.text.len, disasm_text_cap);
    const slen = @min(row.symbol.len, disasm_sym_cap);
    const needed = 4 + 1 + 1 + 4 + 1 + tlen + 1 + slen;
    if (at.* + needed > out.len) return Error.Oversize;
    std.mem.writeInt(u32, out[at.*..][0..4], row.address, .little);
    out[at.* + 4] = row.size;
    out[at.* + 5] = row.decoded;
    @memcpy(out[at.* + 6 ..][0..4], &row.raw);
    out[at.* + 10] = @intCast(tlen);
    @memcpy(out[at.* + 11 ..][0..tlen], row.text[0..tlen]);
    const sym_at = at.* + 11 + tlen;
    out[sym_at] = @intCast(slen);
    @memcpy(out[sym_at + 1 ..][0..slen], row.symbol[0..slen]);
    at.* = sym_at + 1 + slen;
}

pub const Reader = struct {
    rest: []const u8,

    pub fn next(self: *Reader) Error!?DisasmRow {
        if (self.rest.len == 0) return null;
        if (self.rest.len < 12) return Error.Truncated;
        const address = std.mem.readInt(u32, self.rest[0..4], .little);
        const size = self.rest[4];
        const decoded = self.rest[5];
        var raw: [4]u8 = undefined;
        @memcpy(&raw, self.rest[6..10]);
        const tlen: usize = self.rest[10];
        if (11 + tlen + 1 > self.rest.len) return Error.Truncated;
        const text = self.rest[11 .. 11 + tlen];
        const slen: usize = self.rest[11 + tlen];
        const total = 11 + tlen + 1 + slen;
        if (total > self.rest.len) return Error.Truncated;
        const symbol = self.rest[12 + tlen .. total];
        self.rest = self.rest[total..];
        return .{
            .address = address,
            .size = size,
            .decoded = decoded,
            .raw = raw,
            .text = text,
            .symbol = symbol,
        };
    }
};
