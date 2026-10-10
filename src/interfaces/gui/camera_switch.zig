//! Following the camera panel with the CEU's source mid-run (RA8EMU-500).
//!
//! The panel counts every switch in `Panel.changes`. Between emulation
//! steps the runner asks `due` whether the panel moved since the source was
//! last installed, opens the newly picked source, and hands it to `apply`,
//! which closes the old one and installs the new one in place. The CEU
//! captures a whole frame inside one CE write, so a swap between steps
//! always lands between frames, never in the middle of one, and the next
//! armed capture is the first to come from the new source.
const frame_source = @import("ra8_chip").periph.frame_source;

pub const FrameSource = frame_source.FrameSource;

pub const Switcher = struct {
    /// The panel's `changes` when the installed source was put in.
    applied: u32 = 0,

    /// True when the panel switched since the last `apply`.
    pub fn due(self: Switcher, changes: u32) bool {
        return changes != self.applied;
    }

    /// Closes what `source` points at, installs `next` there, and records
    /// that the panel's `changes` are now in effect.
    pub fn apply(self: *Switcher, source: *FrameSource, next: FrameSource, changes: u32) void {
        source.close();
        source.* = next;
        self.applied = changes;
    }

    /// `changes` went to the engine to install (RA8EMU-227): it is in
    /// hand, so the panel is not asked to open it again.
    pub fn posted(self: *Switcher, changes: u32) void {
        self.applied = changes;
    }

    /// The panel's switch could not be opened (a picture that will not
    /// decode, a device that went away): keep the running source and stop
    /// asking until the panel switches again.
    pub fn skip(self: *Switcher, changes: u32) void {
        self.applied = changes;
    }
};
