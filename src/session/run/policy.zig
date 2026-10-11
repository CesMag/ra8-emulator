//! What a run asked for on top of the machine (RA8EMU-1047): real-time
//! pacing against the host clock (RA8EMU-181) and what ends a `--run-for`
//! run early (RA8EMU-186). The session holds it beside the board and hears
//! the board's boundaries and watchdog resets through `run_hook`.
const Board = @import("ra8_board").board.Board;
const run_hook = @import("ra8_board").run_hook;
const pacing = @import("run.zig").pacing;
const soak = @import("run.zig").soak;

pub const RunPolicy = struct {
    pacing: ?pacing.Pacing = null,
    soak: soak.Soak = .{},

    /// Hear `board`'s boundaries and resets; `self` must outlive the run.
    pub fn attach(self: *RunPolicy, board: *Board) void {
        board.run_hook = .{ .context = self, .boundaryFn = boundary, .resetFn = reset };
    }

    fn boundary(context: *anyopaque, now_ns: u64) void {
        const self: *RunPolicy = @ptrCast(@alignCast(context));
        if (self.pacing) |*paced| paced.after(now_ns);
    }

    fn reset(context: *anyopaque, which: run_hook.Reset, now_ns: u64) void {
        const self: *RunPolicy = @ptrCast(@alignCast(context));
        const kind: soak.Kind = switch (which) {
            .watchdog => .watchdog_reset,
            .iwdt => .iwdt_reset,
        };
        self.soak.note(kind, now_ns);
    }
};
