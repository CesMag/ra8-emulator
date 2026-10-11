//! Where the console leaf is scrolled to (RA8EMU-1122). A wheel turn up
//! goes back through the scrollback, a turn down comes forward, Page Up and
//! Page Down move a pane's worth of rows, and at the bottom the leaf follows
//! the output. Scrolled back, the view holds still while new lines arrive:
//! each line the log finishes (or drops off the top) moves the offset back
//! by one, so the same lines stay on screen.
const console_log = @import("console_log.zig");

/// Lines one wheel notch moves.
pub const step: f32 = 3;

/// SDLK_PAGEUP and SDLK_PAGEDOWN.
pub const page_up: u32 = 0x4000_004B;
pub const page_down: u32 = 0x4000_004E;

pub const Scroll = struct {
    /// Finished lines below the leaf's bottom row; 0 follows the output.
    back: usize = 0,
    /// Lines the log had finished, dropped ones included, when last read.
    seen: u64 = 0,
    /// The part of a line a fine wheel (a trackpad) has turned so far.
    rest: f32 = 0,

    /// A wheel turn of `dy` notches over the leaf; up is positive.
    pub fn wheel(self: *Scroll, dy: f32, log: *const console_log.Log) void {
        self.follow(log);
        self.rest += dy * step;
        const whole: i64 = @intFromFloat(@trunc(self.rest));
        self.rest -= @floatFromInt(whole);
        self.moveBy(whole, log);
        // A turn past either end is spent, so turning back moves at once.
        if (self.back == 0) self.rest = @max(self.rest, 0);
        if (self.back == log.lines().len) self.rest = @min(self.rest, 0);
    }

    /// Page Up or Page Down over a leaf `rows` rows high; false for any
    /// other key.
    pub fn page(self: *Scroll, code: u32, rows: usize, log: *const console_log.Log) bool {
        const by: i64 = @intCast(@max(rows, 1));
        self.follow(log);
        self.rest = 0;
        switch (code) {
            page_up => self.moveBy(by, log),
            page_down => self.moveBy(-by, log),
            else => return false,
        }
        return true;
    }

    /// Catches up with the lines the log finished since the last read.
    pub fn follow(self: *Scroll, log: *const console_log.Log) void {
        const total = log.dropped + log.lines().len;
        if (self.back != 0) self.back += @intCast(total - self.seen);
        self.seen = total;
        self.clamp(log);
    }

    fn moveBy(self: *Scroll, lines: i64, log: *const console_log.Log) void {
        self.back = @intCast(@max(@as(i64, @intCast(self.back)) + lines, 0));
        self.clamp(log);
    }

    fn clamp(self: *Scroll, log: *const console_log.Log) void {
        self.back = @min(self.back, log.lines().len);
    }
};
