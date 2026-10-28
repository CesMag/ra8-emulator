//! The seam between a USB/IP bridge and the session's recorded port
//! (row 24). The bridge reports the host traffic it takes off its socket
//! through a `Sink`; a hook that offers a `Port` can also be fed that same
//! traffic back with no socket, which is what a replay does. The board
//! names the seam so the session and the bridge need not know each other.
const std = @import("std");
const usbfs = @import("ra8_chip").periph.usbfs;

/// What the host did, as the bridge saw it.
pub const Kind = enum(u8) {
    /// The host imported the device; the body is the busid it named.
    import = 1,
    /// A USBIP_CMD_SUBMIT: the 48-byte header, then its OUT data.
    submit = 2,
    /// A USBIP_CMD_UNLINK: the 48-byte header.
    unlink = 3,
    /// The host hung up. No body.
    disconnect = 4,
    /// An URB moved or finished; the body is a `Progress`. It is only a
    /// journal entry: a replay never feeds it to the device, a restore
    /// reads it to rebuild the URBs that were in flight.
    progress = 5,
};

/// Where one URB stood after a poll's pump: the body of a `progress` event.
pub const Progress = struct {
    seqnum: u32,
    moved: u32,
    /// The control stage of an endpoint 0 URB, as its enum's number.
    stage: u8,
    /// The URB completed and left its slot.
    done: bool,

    pub const len: usize = 10;

    pub fn encode(self: Progress, out: *[len]u8) void {
        std.mem.writeInt(u32, out[0..4], self.seqnum, .little);
        std.mem.writeInt(u32, out[4..8], self.moved, .little);
        out[8] = self.stage;
        out[9] = @intFromBool(self.done);
    }

    pub fn decode(bytes: []const u8) error{BadValue}!Progress {
        if (bytes.len != len or bytes[9] > 1) return error.BadValue;
        return .{
            .seqnum = std.mem.readInt(u32, bytes[0..4], .little),
            .moved = std.mem.readInt(u32, bytes[4..8], .little),
            .stage = bytes[8],
            .done = bytes[9] == 1,
        };
    }
};

/// The size of a submit's or an unlink's basic header.
pub const header_len: usize = 48;
/// The most OUT data one submit carries.
pub const max_data: usize = 4096;
/// The longest busid an import names.
pub const busid_max: usize = 32;

/// One reported piece of traffic. `pumped` is set on a disconnect that came
/// after the bridge had already advanced its URBs in that poll.
pub const Event = struct {
    kind: Kind,
    pumped: bool = false,
    head: []const u8 = &.{},
    data: []const u8 = &.{},
};

/// Where a bridge reports to.
pub const Sink = struct {
    context: *anyopaque,
    noteFn: *const fn (*anyopaque, Event) void,
    /// Whether the bridge must keep what it read away from the device: the
    /// cursor is in the past, so nothing may reach the machine yet.
    holdFn: *const fn (*anyopaque) bool,
};

/// What a hook offers beyond its poll.
pub const Port = struct {
    /// Report to `sink` from now on; null stops.
    tapFn: *const fn (*anyopaque, ?Sink) void,
    /// Apply one recorded event to `device` with every reply muted.
    feedFn: *const fn (*anyopaque, *usbfs.Device, Event) anyerror!void,
    /// End a replayed poll: advance the replayed URBs one packet.
    pumpFn: *const fn (*anyopaque, *usbfs.Device) void,
    /// Apply one recorded event to the replayed host's state alone, with
    /// the device untouched: a restore rebuilds the URBs in flight at its
    /// position by reading the line's traffic up to it.
    restoreFn: *const fn (*anyopaque, Event) anyerror!void,
    /// Forget what was read but never delivered, and hang up.
    dropFn: *const fn (*anyopaque) void,
};
