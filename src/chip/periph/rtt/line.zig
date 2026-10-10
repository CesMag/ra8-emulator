//! The text a drained RTT ring turns into: carriage returns dropped, lines
//! latched on a newline, and the unfinished tail kept rather than lost.
//!
//! Split from rtt.zig so the drain owns the ring and this owns the words. The
//! shape follows sci.zig's console capture, with two differences dev's model
//! does not have. A line the firmware never terminated is still readable at
//! the end of the run, where dev drops it: a banner printed without a trailing
//! newline simply never appears there. And an over-long line is counted apart
//! from the lines the firmware actually ended, so a report cannot claim a line
//! that was really the model running out of buffer.
const std = @import("std");

pub const limits = struct {
    /// Characters buffered before the model gives up waiting for a newline.
    pub const line: usize = 240;
};

pub const Line = struct {
    last: [limits.line]u8 = undefined,
    last_len: usize = 0,
    held: [limits.line]u8 = undefined,
    held_len: usize = 0,
    /// Lines the firmware ended with a newline.
    lines: u32 = 0,
    /// Lines this model ended because the buffer was full.
    wrapped: u32 = 0,

    /// The newest completed line.
    pub fn slice(self: *const Line) []const u8 {
        return self.last[0..self.last_len];
    }

    /// Text drained but not yet terminated.
    pub fn pending(self: *const Line) []const u8 {
        return self.held[0..self.held_len];
    }

    /// Accumulate one drained byte.
    pub fn feed(self: *Line, byte: u8) void {
        if (byte == '\r') return;
        if (byte == '\n') {
            self.latch();
            self.lines += 1;
            return;
        }
        if (self.held_len == limits.line) {
            self.latch();
            self.wrapped += 1;
        }
        self.held[self.held_len] = byte;
        self.held_len += 1;
    }

    fn latch(self: *Line) void {
        @memcpy(self.last[0..self.held_len], self.held[0..self.held_len]);
        self.last_len = self.held_len;
        self.held_len = 0;
    }

    pub fn quiet(self: *const Line) bool {
        return self.lines == 0 and self.wrapped == 0 and self.held_len == 0;
    }
};
