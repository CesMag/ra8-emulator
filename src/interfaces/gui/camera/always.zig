//! The camera panel's Always for this project, kept between runs
//! (RA8EMU-1124). The project is the directory ra8_gui was started in, and
//! the answer is the marker ra8_host keeps there (camera/webcam/always.zig).
//!
//! `begin` starts the panel from the marker, so a project that answered
//! Always in an earlier run is not asked again. `follow` runs after each
//! click on the panel: it writes the marker once Always is answered and
//! removes it once Always is taken back. A project that will not take the
//! marker only asks again next run. One that will not let it go is the case
//! that matters, because the next run would open the webcam unasked, so
//! `note` says which file to delete, and every later click tries again.
const std = @import("std");
const store = @import("ra8_host").camera.always;
const Panel = @import("panel.zig").Panel;

pub const not_kept = "Always not kept: this project asks again next run";
pub const not_withdrawn = "Always not withdrawn: delete " ++ store.path;

pub const Kept = struct {
    io: std.Io,
    project: std.Io.Dir,
    /// What the project's marker says, as far as this run knows.
    stored: bool,

    /// Start `panel` from what an earlier run left in `project`.
    pub fn begin(io: std.Io, project: std.Io.Dir, panel: *Panel) Kept {
        const stored = store.load(io, project);
        panel.always = stored;
        return .{ .io = io, .project = project, .stored = stored };
    }

    /// Bring the marker in line with `panel`, then read back what the next
    /// run would find. A marker that could not be written or removed stays
    /// out of line, to be tried again on the next call.
    pub fn follow(self: *Kept, panel: *const Panel) void {
        if (panel.always == self.stored) return;
        if (panel.always) {
            store.save(self.io, self.project) catch {};
        } else {
            store.withdraw(self.io, self.project) catch {};
        }
        self.stored = store.load(self.io, self.project);
    }

    /// What the leaf says while the marker is out of line with `panel`.
    pub fn note(self: *const Kept, panel: *const Panel) ?[]const u8 {
        if (panel.always == self.stored) return null;
        return if (panel.always) not_kept else not_withdrawn;
    }
};
