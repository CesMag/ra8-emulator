//! Fills the disassembly pane's snapshot (RA8EMU-1079): from the session,
//! or from bytes the shell read over the session link (RA8EMU-821). Thumb
//! cannot be decoded backwards reliably, so `capture` starts where the
//! caller says: pc to follow execution, or the shell's scroll anchor.
//! ui/disasm_pane.zig draws the result without importing the session.
const std = @import("std");
const disasm = @import("ra8_session").disasm;
const session_api = @import("ra8_session").api;
const session_view = @import("ra8_session").view;
const disasm_pane = @import("ui/disasm_pane.zig");

/// Decodes `row_count` instructions (at most `disasm_pane.max_rows`) of
/// `core` forward from `start`, and reads its pc. An instruction that
/// cannot be read takes two bytes and the next one starts after it. Errors
/// that are not about one address, like a core that is not attached, are
/// returned.
pub fn capture(session: *session_api.Session, core: session_api.Core, start: u32, row_count: usize) anyerror!disasm_pane.Snapshot {
    var snapshot: disasm_pane.Snapshot = .{ .pc = try session.register(core, .pc), .count = @min(row_count, disasm_pane.max_rows) };
    var at = start;
    for (snapshot.lines[0..snapshot.count]) |*line| {
        line.* = try decode(session, core, at);
        at +%= if (line.size == 0) session_view.encoding.narrow else line.size;
    }
    return snapshot;
}

fn decode(session: *session_api.Session, core: session_api.Core, address: u32) anyerror!disasm_pane.Line {
    var line: disasm_pane.Line = .{ .address = address };
    session.read(core, address, line.bytes[0..2]) catch |err| {
        if (unreadable(err)) return line;
        return err;
    };
    const first = std.mem.readInt(u16, line.bytes[0..2], .little);
    const wide = first >= session_view.encoding.wide_first;
    if (wide) session.read(core, address +% 2, line.bytes[2..4]) catch |err| {
        if (unreadable(err)) return line;
        return err;
    };
    line.size = if (wide) 4 else 2;
    decodeInto(&line);
    return line;
}

/// Decodes up to `row_count` instructions (at most `disasm_pane.max_rows`)
/// forward from `pc` out of `bytes` read from `base`, where `readable[i]`
/// says whether byte i came back. An instruction that runs past what was
/// read, or into a byte that was not, is unreadable and takes two bytes.
pub fn decodeRead(pc: u32, base: u32, bytes: []const u8, readable: []const bool, row_count: usize) disasm_pane.Snapshot {
    var snapshot: disasm_pane.Snapshot = .{ .pc = pc, .count = @min(row_count, disasm_pane.max_rows) };
    var at = pc;
    for (snapshot.lines[0..snapshot.count]) |*line| {
        line.* = lineFrom(at, base, bytes, readable);
        at +%= if (line.size == 0) session_view.encoding.narrow else line.size;
    }
    return snapshot;
}

fn lineFrom(address: u32, base: u32, bytes: []const u8, readable: []const bool) disasm_pane.Line {
    var line: disasm_pane.Line = .{ .address = address };
    const offset: usize = address -% base;
    if (!present(offset, readable)) return line;
    @memcpy(line.bytes[0..2], bytes[offset..][0..2]);
    const first = std.mem.readInt(u16, line.bytes[0..2], .little);
    const wide = first >= session_view.encoding.wide_first;
    if (wide) {
        if (!present(offset + 2, readable)) return line;
        @memcpy(line.bytes[2..4], bytes[offset + 2 ..][0..2]);
    }
    line.size = if (wide) 4 else 2;
    decodeInto(&line);
    return line;
}

/// Whether the halfword at `offset` was read in full.
fn present(offset: usize, readable: []const bool) bool {
    if (offset > readable.len or readable.len - offset < 2) return false;
    return readable[offset] and readable[offset + 1];
}

/// Fills a read line's text, leaving it undecoded when the bytes are not
/// an instruction.
fn decodeInto(line: *disasm_pane.Line) void {
    const decoded = disasm.one(line.address, line.bytes[0..line.size]) catch return;
    line.setText(decoded.slice());
    line.decoded = true;
}

/// The bus errors that mean this address cannot be read.
fn unreadable(err: anyerror) bool {
    return err == error.Unmapped or err == error.SecurityViolation;
}
