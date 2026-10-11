//! The time bar's model side (RA8EMU-1086): fills the bar's plain view from
//! the status, the speed field and the clock readout, and turns a click into
//! a run or a pause of the shell's sliced run (src/interfaces/gui/shell/run.zig, RA8EMU-1118)
//! or a step on the session link. The bar itself (gui/ui/time_bar.zig) only
//! lays out, paints and hit-tests.
const proto = @import("ra8_rpc").session.rpc;
const bar = @import("../ui/time_bar.zig");
const status_bar = @import("../status/bar.zig");
const speed_field = @import("../speed_field.zig");
const time_readout = @import("readout.zig");
const session_link = @import("../session_link.zig");
const shell_run = @import("../shell/run.zig");

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

/// A click on `control`. Run lights `run` on a halted core, and the shell's
/// frames keep it going in slices from there; nothing is sent here, so the
/// window never waits on a run. Pause stops it between slices. Step runs
/// one instruction on a halted core. The field takes the keyboard in the
/// shell, so a click on it sends nothing.
pub fn press(control: bar.Control, status: *Status, run: *shell_run.Run, link: *Link) !void {
    switch (control) {
        .run => {
            const at = switch (status.run) {
                .halted => |halt| halt.address,
                .unknown, .running => return,
            };
            run.start(at);
            status.running();
        },
        .step => if (!run.lit and status.run == .halted) try status.go(link, proto.RunMode.step, step_budget),
        .pause => run.pause(),
        .field => {},
    }
}
