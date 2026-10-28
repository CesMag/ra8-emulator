//! The imported connection's URB traffic (RA8EMU-75 slice 4b), still with
//! no socket of its own: `receive` reads one CMD_SUBMIT or CMD_UNLINK off
//! any reader, `pump` advances every URB in flight one packet and writes
//! RET_SUBMIT for those that finished. The kernel keeps several URBs open
//! at once (an IN poll beside an OUT write), so each gets its own slot and
//! they finish in whatever order the firmware serves them; replies carry
//! their seqnum, which is all usbip asks.
const std = @import("std");
const wire = @import("wire.zig");
const urb = @import("urb.zig");
const usbfs = @import("ra8_chip").periph.usbfs;
const traffic = @import("ra8_board").usb.traffic;

pub const slot_count = 8;
/// The most data one URB moves here; cdc-acm asks for 1280 at most.
pub const max_length = 4096;
pub const emsgsize: i32 = -90;

pub const Error = error{ Busy, Short } || wire.Error;

const Slot = struct {
    transfer: urb.Transfer,
    data: [max_length]u8 = undefined,
};

pub const Session = struct {
    slots: [slot_count]?Slot = @splat(null),
    /// Told of each command taken whole, for the recorded port.
    sink: ?traffic.Sink = null,

    /// Read one command. False on a clean hangup before its header.
    pub fn receive(self: *Session, reader: *std.Io.Reader, writer: *std.Io.Writer) !bool {
        var header: [wire.basic_len]u8 = undefined;
        const got = try reader.readSliceShort(&header);
        if (got == 0) return false;
        if (got < header.len) return error.Short;
        switch (try wire.command(&header)) {
            wire.cmd.submit => try self.submit(try wire.Submit.decode(&header), &header, reader, writer),
            wire.cmd.unlink => try self.unlink(try wire.Unlink.decode(&header), &header, writer),
            else => return error.BadCommand,
        }
        return true;
    }

    /// Advance every URB in flight; returns how many finished.
    pub fn pump(self: *Session, device: *usbfs.Device, writer: *std.Io.Writer) !usize {
        var finished: usize = 0;
        for (&self.slots) |*entry| {
            const slot = &(entry.* orelse continue);
            const in = slot.transfer.submit.direction == .in;
            const length = @min(slot.transfer.submit.length, max_length);
            const out_data: []const u8 = if (in) &.{} else slot.data[0..length];
            const in_buf: []u8 = if (in) slot.data[0..length] else &.{};
            const reply = slot.transfer.advance(device, out_data, in_buf) orelse continue;
            try answer(writer, slot.transfer.submit.seqnum, reply, if (in) slot.data[0..reply.actual] else &.{});
            entry.* = null;
            finished += 1;
        }
        return finished;
    }

    /// URBs still waiting on the firmware.
    pub fn pending(self: *const Session) usize {
        var count: usize = 0;
        for (self.slots) |entry| count += @intFromBool(entry != null);
        return count;
    }

    fn submit(self: *Session, request: wire.Submit, head: []const u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        const carried = request.outBytes();
        if (request.length > max_length) {
            try reader.discardAll(carried);
            return answer(writer, request.seqnum, .{ .status = emsgsize, .actual = 0 }, &.{});
        }
        const entry = self.free() orelse return error.Busy;
        entry.* = .{ .transfer = .{ .submit = request } };
        try reader.readSliceAll(entry.*.?.data[0..carried]);
        self.note(.submit, head, entry.*.?.data[0..carried]);
    }

    fn unlink(self: *Session, request: wire.Unlink, head: []const u8, writer: *std.Io.Writer) !void {
        self.note(.unlink, head, &.{});
        var status: i32 = 0;
        for (&self.slots) |*entry| {
            const slot = entry.* orelse continue;
            if (slot.transfer.submit.seqnum != request.victim) continue;
            entry.* = null;
            status = urb.econnreset;
        }
        var out: [wire.basic_len]u8 = undefined;
        wire.retUnlink(&out, request.seqnum, status);
        try writer.writeAll(&out);
    }

    fn note(self: *const Session, kind: traffic.Kind, head: []const u8, data: []const u8) void {
        const sink = self.sink orelse return;
        sink.noteFn(sink.context, .{ .kind = kind, .head = head, .data = data });
    }

    fn free(self: *Session) ?*?Slot {
        for (&self.slots) |*entry| if (entry.* == null) return entry;
        return null;
    }
};

fn answer(writer: *std.Io.Writer, seqnum: u32, reply: urb.Reply, data: []const u8) !void {
    var out: [wire.basic_len]u8 = undefined;
    wire.retSubmit(&out, seqnum, reply.status, reply.actual);
    try writer.writeAll(&out);
    try writer.writeAll(data);
}
