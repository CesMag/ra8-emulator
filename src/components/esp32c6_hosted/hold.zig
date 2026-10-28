//! The application's hold on the C6's host traffic (time-travel design
//! section 11). While the debugger replays recorded history the machine is
//! the past's: host sockets are neither read into it nor written from it,
//! so asynchronous host traffic never forks and never reaches a rewound
//! machine. Held bytes wait in the host's own socket buffers and arrive in
//! their order once the run is back at the recorded end and the hold lifts.

/// Answers whether host traffic is held right now.
pub const Hold = struct {
    context: *anyopaque,
    heldFn: *const fn (*anyopaque) bool,
};

/// The two places a host frame reaches the guest's queue: while the
/// bridge forwards a frame the guest sent, and when it polls its sockets.
pub const Site = enum(u8) { forward = 0, poll = 1 };

/// What a host frame is: socket bytes, or an answer to a DNS question.
pub const Kind = enum(u8) { bytes = 0, answer = 1 };

/// A recorded frame handed back to land: what it is and its length.
pub const Due = struct { kind: Kind, len: usize };

/// The application's record of the host frames that land on the guest's
/// queue (row 24). The bridge tells it each frame as it lands; while the
/// hold is up the bridge reads no socket, and the frames the record has
/// for the same call land instead, so a replay hears exactly what the
/// recorded run did, with no host socket involved.
pub const Landing = struct {
    context: *anyopaque,
    /// The bridge entered `site`; counts the call.
    enterFn: *const fn (*anyopaque, Site) void,
    /// A live host frame (its Ethernet bytes) just landed on the queue.
    landedFn: *const fn (*anyopaque, Site, Kind, []const u8) void,
    /// The next recorded frame due at the call just entered, copied into
    /// `out`; null when none is left.
    dueFn: *const fn (*anyopaque, Site, out: []u8) ?Due,
    /// A recorded frame did not fit the queue it was recorded on.
    failFn: *const fn (*anyopaque) void,
};
