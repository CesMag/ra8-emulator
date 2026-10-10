//! The panel's frame boundary on the board's virtual time base (RA8EMU-573).
//!
//! The GLCDC model composites a frame only when something calls `scanOut`,
//! and without a viewer the only caller is the end-of-run report. A viewer
//! that wants every frame a run shows (--frames-out) installs a Vsync on the
//! output stage; the board boundary hands it the time after each chunk, and
//! once a frame period has gone by the viewer's sink scans the panel.
//!
//! OPT-IN, on purpose: an in-run scan raises VPOS at the frame cadence, which
//! moves when a driver polling it sees a frame land. With no viewer installed
//! nothing here runs, the GLCDC still scans only for the report, and every
//! corpus row stays byte identical.
//!
//! DECISION: a fixed 60 Hz period. PANELCLK's divider is modelled
//! (sys.zig) but not the clock it divides, so a period derived from the
//! TCON totals would rest on a guessed source rate. A chunk that covers
//! several periods yields one scan, and the periods it swallowed are counted.
pub const default_period_ns: u64 = 16_666_667;

/// Who scans when a frame boundary passes. The sink does the scan itself, so
/// it can size its capture buffer to the panel as the firmware has it now.
pub const Sink = struct {
    context: *anyopaque,
    frame: *const fn (context: *anyopaque, when_ns: u64) void,
    /// Polled after every chunk, frame boundary or not, for a viewer that
    /// waits on the picture holding still (the e-ink LUT status).
    settle: ?*const fn (context: *anyopaque, now_ns: u64) anyerror!void = null,
};

pub const Vsync = struct {
    sink: Sink,
    period_ns: u64 = default_period_ns,
    next_ns: u64 = default_period_ns,
    /// Frame periods that ended.
    boundaries: u64 = 0,
    /// Of those, the ones that ended inside a chunk another one also ended
    /// in: frames the panel showed and the viewer never saw.
    swallowed: u64 = 0,

    /// True once at least one period ended at or before `now_ns`; the next
    /// boundary moves past `now_ns`.
    pub fn due(self: *Vsync, now_ns: u64) bool {
        if (now_ns < self.next_ns) return false;
        const ended = (now_ns - self.next_ns) / self.period_ns + 1;
        self.next_ns += ended * self.period_ns;
        self.boundaries += ended;
        self.swallowed += ended - 1;
        return true;
    }

    /// The sink's settle poll, when it has one.
    pub fn settle(self: *Vsync, now_ns: u64) !void {
        if (self.sink.settle) |poll| try poll(self.sink.context, now_ns);
    }

    /// Called by the board after each chunk.
    pub fn tick(self: *Vsync, now_ns: u64) void {
        if (self.due(now_ns)) self.sink.frame(self.sink.context, now_ns);
    }
};
