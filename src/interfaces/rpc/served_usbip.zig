//! A served session's USB/IP bridge (row 24): whenever the session keeps a
//! history, the recorded port goes around the bridge the application put on
//! the board's USB tick, so the host traffic the guest's USBFS device is
//! served is recorded and replayed with no socket. A session with no
//! history, or a board with no bridge, is left as it is.
const board_usbip = @import("ra8_session").board.recorded_usbip;
const served_setup = @import("served_setup.zig");

fn recording(self: *served_setup.Served) bool {
    return self.history != null or self.ram_history != null;
}

/// Wraps the board's bridge in the recorded port when the session keeps a
/// history. Call it once the bridge is on the board.
pub fn attach(self: *served_setup.Served) !void {
    if (!recording(self)) return;
    try board_usbip.attach(self.gpa, self.owner.session(), &self.owner.board().usb);
}

/// Takes the recorded port off the bridge before the session goes.
pub fn release(self: *served_setup.Served) void {
    board_usbip.release(&self.owner.board().usb, self.owner.session());
}
