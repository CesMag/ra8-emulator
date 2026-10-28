//! Host input polled at board boundaries and queued on the console SCI.
const sci = @import("sci.zig");
const sci_reply = @import("reply.zig");
const ByteSource = @import("../byte_source.zig").ByteSource;

pub const Hook = struct {
    context: *anyopaque,
    feedFn: *const fn (context: *anyopaque, bytes: []const u8) void,
    /// True while the host must not be heard: a replay's keystrokes come
    /// from its history. Null never holds.
    heldFn: ?*const fn (context: *anyopaque) bool = null,
};

pub const Input = struct {
    /// `--console`: the host stream typed into SCI8, filled by the
    /// application (the CLI's own stdin). Null means no console input.
    source: ?ByteSource = null,
    /// `--console-reply`: typed after its prompt, with or without stdin.
    reply: sci_reply.Reply = .{},
    /// Choke point routing for console keystrokes (RA8EMU-1196, slice 20).
    hook: ?Hook = null,

    /// Move bytes waiting on the host stream into SCI8's RX ring.
    /// The read never waits, which keeps the run loop in control of progress.
    pub fn poll(self: *Input, unit: *sci.Sci) void {
        if (self.hook) |h| if (h.heldFn) |held| if (held(h.context)) {
            // Stdin waits in the host's buffer; the reply the guest's prompt
            // asked for is among the recorded keystrokes, not typed again.
            if (self.reply.due) {
                self.reply.due = false;
                self.reply.sent = true;
            }
            return;
        };
        if (self.reply.due) {
            self.reply.due = false;
            self.reply.sent = true;
            if (self.hook) |h| {
                h.feedFn(h.context, self.reply.text);
                h.feedFn(h.context, "\n");
            } else {
                unit.feed(sci.console_channel, self.reply.text);
                unit.feed(sci.console_channel, "\n");
            }
        }
        const source = self.source orelse return;
        var bytes: [256]u8 = undefined;
        const count = source.read(&bytes) orelse return;
        if (count == 0) {
            self.source = null;
            return;
        }
        if (self.hook) |h| {
            h.feedFn(h.context, bytes[0..count]);
            return;
        }
        unit.feed(sci.console_channel, bytes[0..count]);
    }
};
