//! `--watch` fed through the debugger's stop machine.
//!
//! src/session/stop_machine.zig owns the watch table the command layer and
//! the GDB stub stop on. `--watch` puts its window in that same table, so
//! the flag and an interactive watch decide what a matching store is the
//! same way.
//!
//! The flag never stops a run. An interactive watch halts on the hit; this
//! one takes the hit as a store to record, clears it, and lets the run go
//! on, so the report keeps every store it always kept.
const stop_machine = @import("../stop_machine.zig");
const watch_table = @import("table.zig");
const watchpoint = @import("../watchpoint.zig");

/// The watched place, the machine that matches stores against it, and the
/// table entry that names it.
pub const Link = struct {
    machine: stop_machine.Machine = .{},
    id: watch_table.Id = 0,
    watched: *watchpoint.Watched,

    /// Hand the machine one store. A store the table matches is recorded
    /// with the pc and lr it was made from, and the stop it would cause is
    /// dropped, because the flag records rather than halts.
    pub fn store(self: *Link, pc: u32, lr: u32, address: u32, width: u8, value: u32) void {
        self.machine.onAccess(address, width, .write, value);
        if (self.machine.watch_pending == null) return;
        self.machine.watch_pending = null;
        self.watched.record(pc, lr, address, width, value);
    }

    /// The table's own count of matching stores.
    pub fn seen(self: *const Link) u32 {
        const entry = self.machine.watches.get(self.id) orelse return 0;
        return entry.seen;
    }
};

/// Put `watched`'s window in a fresh machine's watch table and set it
/// running. The window is the four bytes the flag has always watched.
pub fn link(watched: *watchpoint.Watched) Link {
    var made = Link{ .watched = watched };
    const window = watch_table.Watch.span(watched.address, watchpoint.limits.window, .write) catch unreachable;
    made.id = made.machine.addWatch(window) catch unreachable;
    made.machine.begin();
    return made;
}
