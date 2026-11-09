//! Session execution for the shell: local/server exchanges and paced run
//! slices. It also settles pauses and real refusals into the status and
//! refreshes the leaves. The arrival pump is pump.zig; input and drawing
//! stay in loop.zig.
const Shell = @import("loop.zig").Shell;
const shell_pump = @import("pump.zig");

/// Most arrivals taken off the link in one frame, so a chatty session cannot starve the window.
pub const max_arrivals: usize = 64;

/// One round with the session: send what is due and take what has
/// arrived, and when the session is served in this process let it answer
/// and take that too.
pub fn exchange(self: *Shell) !void {
    if (self.link) |link| self.snaps.rewind(link);
    try self.pump();
    if (self.server) |server| try server.answer();
    if (self.listener) |listener| try listener.answer();
    if (self.link) |link| try shell_pump.drain(self, link);
}

/// Pay what this frame owes a lit run (shell_run.zig), one slice at a
/// time, each answered and taken before the next goes out; a session in
/// another process answers in its own time, one slice a frame. A session
/// on a thread of its own is paid between frames too: .fresh arms the
/// frame clock once, .same pays without arming it again.
pub fn paySlices(self: *Shell, frame: enum { fresh, same }) !void {
    const time = self.time orelse return;
    const link = self.link orelse return;
    defer settle(self);
    if (frame == .fresh) time.frame(link, self.now());
    // No slice goes out behind a load: the image it would run may be gone.
    while (self.drained and self.status.load_id == null and time.run.next(link, self.now())) {
        const server = self.server orelse return;
        while (true) {
            try server.answer();
            if (self.listener) |listener| try listener.answer();
            try shell_pump.drain(self, link);
            if (self.worker != null or !self.drained or time.run.slice_id == null) break;
        }
    }
}

/// A pause the time bar settled: the status bar shows the halt, and the
/// core's leaves read it again.
pub fn settle(self: *Shell) void {
    const time = self.time orelse return;
    if (!time.settle(&self.status)) return;
    if (self.registers) |registers| registers.refresh();
    if (self.stack) |stack| stack.refresh();
    if (self.source) |source| source.refresh();
    if (self.locals) |locals| locals.refresh();
}
