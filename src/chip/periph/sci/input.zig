//! Host input polled at board boundaries and queued on the console SCI.
const sci = @import("sci.zig");
const sci_reply = @import("reply.zig");
const ByteSource = @import("../byte_source.zig").ByteSource;

pub const Input = struct {
    /// `--console`: the host stream typed into SCI8, filled by the
    /// application (the CLI's own stdin). Null means no console input.
    source: ?ByteSource = null,
    /// `--console-reply`: typed after its prompt, with or without stdin.
    reply: sci_reply.Reply = .{},

    /// Move bytes waiting on the host stream into SCI8's RX ring.
    /// The read never waits, which keeps the run loop in control of progress.
    pub fn poll(self: *Input, unit: *sci.Sci) void {
        self.reply.poll(unit);
        const source = self.source orelse return;
        var bytes: [256]u8 = undefined;
        const count = source.read(&bytes) orelse return;
        if (count == 0) {
            self.source = null;
            return;
        }
        unit.feed(sci.console_channel, bytes[0..count]);
    }
};
