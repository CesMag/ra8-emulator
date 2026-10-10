//! The `cpu_load` object of `--report json` (RA8EMU-266): the table
//! `--cpu-load` prints, per core, from the same tracer and the same split
//! (src/session/rtos_report.zig). Null when `--cpu-load` was not given; a
//! core with no ThreadX to trace is null inside it.
//!
//! Each owner carries its kind (`before`, `idle`, `thread`, `exception`),
//! its id (the thread's control block or the exception number; null for
//! `before` and `idle`), its name where one can be read, its instructions
//! and its share in permille, so a core's shares add up to exactly 1000.
const rtos_report = @import("ra8_session").rtos_report;
const rtos_load = @import("ra8_session").rtos_load;
const names = @import("ra8_session").rtos_names;
const json = @import("json.zig");

/// The traced cores the load is read from.
pub const Load = struct {
    cpu0: ?rtos_report.Side = null,
    cpu1: ?rtos_report.Side = null,
};

/// The `cpu_load` object, or null when no load was asked for.
pub fn section(j: anytype, found: ?*const Load) !void {
    const of = found orelse return j.field("cpu_load", null);
    try j.open("cpu_load", '{');
    try contents(j, of);
    try j.close('}');
}

/// The same per-core object as the report field, without its outer key.
pub fn document(out: anytype, found: *const Load) !void {
    var j = json.over(out);
    try j.open(null, '{');
    try contents(&j, found);
    try j.close('}');
    try out.writeByte('\n');
}

fn contents(j: anytype, found: *const Load) !void {
    try core(j, "cpu0", found.cpu0);
    try core(j, "cpu1", found.cpu1);
}

fn core(j: anytype, key: []const u8, side: ?rtos_report.Side) !void {
    const one = side orelse return j.field(key, null);
    const made = rtos_report.table(one.tracer);
    try j.open(key, '{');
    try j.field("instructions", made.total);
    try j.open("owners", '[');
    for (made.rows(), 0..) |slot, index| try owner(j, slot, made.shares[index], one.memory);
    try j.close(']');
    try j.open("other", '{');
    try j.field("instructions", made.other);
    try j.field("permille", made.shares[made.len]);
    try j.close('}');
    try j.close('}');
}

fn owner(j: anytype, slot: rtos_load.Slot, permille: u64, memory: anytype) !void {
    var buffer: [names.longest]u8 = undefined;
    const id: ?u32 = switch (slot.owner.kind) {
        .before, .idle => null,
        .thread, .exception => slot.owner.id,
    };
    try j.open(null, '{');
    try j.field("kind", @tagName(slot.owner.kind));
    try j.field("id", id);
    try j.field("name", rtos_report.ownerName(slot.owner, memory, &buffer));
    try j.field("instructions", slot.ticks);
    try j.field("permille", permille);
    try j.close('}');
}
