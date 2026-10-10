//! A wall clock a test moves by hand, for the shell's run pacing
//! (src/interfaces/gui/wall_clock.zig).
const gui_app = @import("gui_app");
const wall_clock = gui_app.wall_clock;

pub const Manual = struct {
    now_ns: u64 = 0,
    /// Added after every read, so code that waits on the clock gets there.
    step_ns: u64 = 0,

    pub fn clock(self: *Manual) wall_clock.Clock {
        return .{ .context = self, .nowFn = readFrom };
    }

    pub fn read(self: *Manual) u64 {
        const at = self.now_ns;
        self.now_ns += self.step_ns;
        return at;
    }

    fn readFrom(context: *anyopaque) u64 {
        const self: *Manual = @ptrCast(@alignCast(context));
        return self.read();
    }
};
