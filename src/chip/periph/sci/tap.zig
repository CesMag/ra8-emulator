//! Every byte any SCI channel actually sends, for a watcher outside the
//! run (RA8EMU-206: the host window's console panes). Optional and off by
//! default; it runs on the engine thread, at the moment the transmitter
//! takes the byte, so it must only record and never block.
pub const Tap = struct {
    ctx: *anyopaque,
    sent: *const fn (ctx: *anyopaque, channel: usize, byte: u8) void,
};
