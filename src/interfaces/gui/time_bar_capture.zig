//! The time bar's model side (RA8EMU-1086): fills the bar's plain view from
//! the status, the speed field and the clock readout, and turns a click into
//! a run, a step or a pause on the session link. The bar itself
//! (gui/ui/time_bar.zig) only lays out, paints and hit-tests.
const proto = @import("ra8_rpc").session_rpc;
const bar = @import("ui/time_bar.zig");
const status_bar = @import("status_bar.zig");
const speed_field = @import("speed_field.zig");
const time_readout = @import("time_readout.zig");
const session_link = @import("session_link.zig");

const Status = status_bar.Status;
const Link = session_link.Link;

comptime {
    if (bar.field_chars != speed_field.max_chars) @compileError("the time bar's field width must match speed_field.max_chars");
}

/// A step is one instruction; the session takes no budget for it.
pub const step_budget: u64 = 0;

/// The buffers the view's field and clock text live in; they outlive the view.
pub const Texts = struct {
    field: [speed_field.max_chars + 4]u8 = undefined,
    clock: [96]u8 = undefined,
};

/// The bar's view of `status`, `field` and `readout`, its text in `texts`.
pub fn view(texts: *Texts, status: *const Status, field: *const speed_field.Field, readout: *const time_readout.Readout, editing: bool) bar.View {
    return .{
        .run_lit = status.run == .running,
        .pause_lit = status.run == .halted,
        .field = field.shown(&texts.field) catch texts.field[0..0],
        .field_refused = field.refused != null,
        .editing = editing,
        .clock = readout.text(field.applied, &texts.clock) catch texts.clock[0..0],
    };
}

/// A click on `control`. Run continues from wherever the core stopped (the
/// session refuses a fresh run once started) for `run_budget` instructions;
/// Step runs one; Pause asks the session to stop. The field takes the
/// keyboard in the shell, so a click on it sends nothing.
pub fn press(control: bar.Control, status: *Status, link: *Link, run_budget: u64) !void {
    switch (control) {
        .run => try status.go(link, proto.RunMode.cont, run_budget),
        .step => try status.go(link, proto.RunMode.step, step_budget),
        .pause => try status.pause(link),
        .field => {},
    }
}
