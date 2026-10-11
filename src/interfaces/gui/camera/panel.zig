//! The board view's camera panel state (RA8EMU-500): which source the CEU
//! captures from, and the consent gate the webcam passes first.
//!
//! Picking the webcam never opens it. It opens the permission dialog, and
//! only Allow once or Always for this project makes the webcam the active
//! source; Cancel leaves the old source running. Allow once lasts until the
//! user picks another source, so coming back to the webcam asks again.
//! Always holds for the rest of the run. `changes` counts switches so the
//! runner knows to reopen the CEU's source mid-run without a restart.
//! Drawing the panel and persisting Always to the project are later slices.
const source_spec = @import("ra8_host").camera.source_spec;

pub const Kind = source_spec.Kind;

/// The three buttons of the webcam permission dialog.
pub const Answer = enum { allow_once, always, cancel };

pub const Panel = struct {
    /// The source the CEU captures from now.
    active: Kind = .gradient,
    /// The webcam permission dialog is open.
    asking: bool = false,
    /// Always for this project was answered this run.
    always: bool = false,
    /// How many times `active` has changed.
    changes: u32 = 0,

    /// The user picked `kind` in the panel.
    pub fn pick(self: *Panel, kind: Kind) void {
        self.asking = false;
        if (kind == self.active) return;
        if (kind == .webcam and !self.always) {
            self.asking = true;
            return;
        }
        self.switchTo(kind);
    }

    /// The user answered the webcam dialog. Ignored when it is not open.
    pub fn answer(self: *Panel, reply: Answer) void {
        if (!self.asking) return;
        self.asking = false;
        switch (reply) {
            .cancel => {},
            .allow_once => self.switchTo(.webcam),
            .always => {
                self.always = true;
                self.switchTo(.webcam);
            },
        }
    }

    /// The "camera on" indicator: lit only while the webcam is the source.
    pub fn cameraOn(self: Panel) bool {
        return self.active == .webcam;
    }

    /// The active source's file changed, so the runner opens it again.
    pub fn reopen(self: *Panel) void {
        self.changes += 1;
    }

    fn switchTo(self: *Panel, kind: Kind) void {
        self.active = kind;
        self.changes += 1;
    }
};
