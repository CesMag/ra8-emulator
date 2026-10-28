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
    /// Forget what was read but never delivered, and hang up.
    dropFn: *const fn (*anyopaque) void,
};
