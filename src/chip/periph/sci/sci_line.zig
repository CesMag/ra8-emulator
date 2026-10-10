//! The console line the firmware printed, accumulated one transmitted byte
//! at a time.
//!
//! SCI_B hands this file every byte channel 8 actually sends
//! (src/chip/periph/sci/sci.zig), and it keeps the last finished line so the run can
//! be told what the firmware said. It is its own file for the reason the
//! RTT probe's line buffer is (src/chip/periph/rtt/rtt_line.zig): what a line is, and
//! what happens to one that never ends, is a separate question from what a
//! serial channel does with a byte.

/// How long a line may get before it stops growing. A line past this is
/// truncated rather than wrapped onto itself, so the report never shows a
/// line the firmware did not print.
pub const limits = struct {
    pub const line: usize = 512;
};

/// Where a finished line can be sent as soon as its newline arrives.
pub const Sink = struct {
    context: ?*anyopaque = null,
    writeFn: *const fn (?*anyopaque, []const u8) anyerror!void,
};

/// The captured console line. The last finished line is kept as a slice, not a
/// terminated buffer: nothing here crosses a C boundary.
pub const Line = struct {
    last: [limits.line]u8 = undefined,
    last_len: usize = 0,
    pending: [limits.line]u8 = undefined,
    pending_len: usize = 0,
    lines: u32 = 0,
    sink: ?Sink = null,
    sink_failed: bool = false,

    pub fn setSink(self: *Line, sink: ?Sink) void {
        self.sink = sink;
        self.sink_failed = false;
    }

    pub fn slice(self: *const Line) []const u8 {
        return self.last[0..self.last_len];
    }

    /// Accumulate one transmitted byte. A newline latches the pending line,
    /// carriage return is dropped, and an over-long line stops growing rather
    /// than wrapping onto itself.
    pub fn feed(self: *Line, byte: u8) void {
        if (byte == '\n') {
            @memcpy(self.last[0..self.pending_len], self.pending[0..self.pending_len]);
            self.last_len = self.pending_len;
            self.pending_len = 0;
            self.lines += 1;
            if (self.sink) |sink| sink.writeFn(sink.context, self.slice()) catch {
                self.sink_failed = true;
            };
            return;
        }
        if (byte == '\r' or self.pending_len == limits.line) return;
        self.pending[self.pending_len] = byte;
        self.pending_len += 1;
    }
};
