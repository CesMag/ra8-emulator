//! Fills the periph pane's Snapshot through the session (RA8EMU-819): the
//! blocks the bus maps (818's pairing table names their models) and the
//! selected block's registers, read through the session's memory read at
//! the register's width. ui/periph_pane.zig never imports the session.
const std = @import("std");
const session_api = @import("ra8_session").api;
const periph_list = @import("ra8_session").periph_list;
const periph_pane = @import("ui/periph_pane.zig");

/// The bus's blocks, in the order the board added them, into `into`.
pub fn blocks(bus: anytype, into: *periph_pane.Snapshot) void {
    into.block_count = 0;
    for (periph_list.blocks(bus)) |block| {
        if (into.block_count == periph_pane.max_blocks) break;
        into.blocks[into.block_count] = .{ .name = block.name, .base = block.base, .size = block.size };
        into.block_count += 1;
    }
}

/// The blocks, and the registers of `block` with their live values. A
/// block no model is paired with still lists its row; its registers stay
/// empty. `selected` names the block the registers came from when it is on
/// the bus.
pub fn capture(session: *session_api.Session, core: session_api.Core, bus: anytype, block: []const u8) anyerror!periph_pane.Snapshot {
    var snapshot: periph_pane.Snapshot = .{};
    blocks(bus, &snapshot);
    for (0..snapshot.block_count) |index| {
        if (std.ascii.eqlIgnoreCase(snapshot.blocks[index].name, block)) snapshot.selected = index;
    }
    const regs = periph_list.registers(block) orelse return snapshot;
    const base = snapshot.blocks[snapshot.selected].base;
    for (regs) |reg| {
        if (snapshot.reg_count == periph_pane.max_registers) break;
        const index = snapshot.reg_count;
        snapshot.regs[index] = .{ .name = reg.name, .offset = reg.offset, .width = reg.width };
        snapshot.readable[index] = readValue(session, core, base +% reg.offset, reg.width, &snapshot.values[index]);
        snapshot.reg_count += 1;
    }
    return snapshot;
}

/// Reads `width` bytes at `address`; an undeclared width (0) reads a full
/// word. A bus that refuses the read leaves `value` alone and says so.
fn readValue(session: *session_api.Session, core: session_api.Core, address: u32, width: u8, value: *u32) bool {
    const length: usize = switch (width) {
        1 => 1,
        2 => 2,
        else => 4,
    };
    var bytes: [4]u8 = @splat(0);
    session.read(core, address, bytes[0..length]) catch return false;
    var read: u32 = 0;
    for (bytes[0..length], 0..) |byte, index| read |= @as(u32, byte) << @intCast(8 * index);
    value.* = read;
    return true;
}
