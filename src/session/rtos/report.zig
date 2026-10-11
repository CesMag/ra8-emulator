//! What `--trace-rtos` and `--cpu-load` print as a run ends (RA8EMU-267).
//!
//! Both read one tracer: the trace it kept, and the load its trace fed as
//! every event went by (src/session/rtos/load.zig). The load table gives each
//! owner its ticks and its share of the core's run in tenths of a percent,
//! split by largest remainder so a core's shares add up to exactly 100.0%.
//!
//! Load is counted in instructions retired on the core, in the
//! timebase's elapsed count, which moves a chunk at a time.
const std = @import("std");
const rtos_hook = @import("hook.zig");
const rtos_load = @import("load.zig");
const names = @import("names.zig");
const isr = @import("isr.zig");
const rtos_file = @import("file.zig");

pub const limits = struct {
    /// A whole core's run, in the tenths of a percent shares are counted in.
    pub const whole: u64 = 1000;
    /// Rows a table can have: every kept owner, then `other`.
    pub const rows: usize = rtos_load.limits.slots + 1;
};

/// One traced core and the memory its threads' names are read through,
/// as `--report json` takes it (RA8EMU-266).
pub const Side = struct {
    tracer: *const rtos_hook.Tracer,
    memory: rtos_hook.Memory,
};

/// The side for `tracer`, or null when nothing was traced.
pub fn sideOf(tracer: ?*const rtos_hook.Tracer, memory: rtos_hook.Memory) ?Side {
    const one = tracer orelse return null;
    return .{ .tracer = one, .memory = memory };
}

/// The trace when `--trace-rtos` asked, then the load when `--cpu-load` did.
/// Under `--report json` the load is in the document, so its table is not
/// printed again.
pub fn all(out: anytype, io: std.Io, options: anytype, tracer: ?*const rtos_hook.Tracer, memory: anytype) !void {
    if (options.trace_rtos) try rtos_hook.print(out, tracer, memory);
    if (options.cpu_load and !asJson(options)) try load(out, tracer, memory);
    const one = tracer orelse return;
    if (outPath(options)) |path| try rtos_file.save(io, path, one.core, &one.trace);
}

/// `--trace-rtos-out`, when the options carry it and it was given.
fn outPath(options: anytype) ?[]const u8 {
    if (!@hasField(Fields(@TypeOf(options)), "trace_rtos_out")) return null;
    return options.trace_rtos_out;
}

/// `--report json`, when the options carry it.
fn asJson(options: anytype) bool {
    if (!@hasField(Fields(@TypeOf(options)), "report_json")) return false;
    return options.report_json;
}

fn Fields(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
}

/// One core's load as the run ends: its owners, `other`, and each one's
/// share in tenths of a percent (`shares[len]` is `other`'s).
pub const Table = struct {
    core: u1,
    total: u64,
    other: u64,
    slots: [rtos_load.limits.slots]rtos_load.Slot = undefined,
    len: usize = 0,
    shares: [limits.rows]u64 = @splat(0),

    pub fn rows(self: *const Table) []const rtos_load.Slot {
        return self.slots[0..self.len];
    }
};

/// The tracer's core, charged up to its clock now.
pub fn table(one: *const rtos_hook.Tracer) Table {
    var copy = one.trace.load;
    copy.finish(one.loadClock());
    const slots = copy.rows(one.core);
    var made = Table{ .core = one.core, .total = copy.total(one.core), .other = copy.cores[one.core].other, .len = slots.len };
    @memcpy(made.slots[0..slots.len], slots);
    if (made.total == 0) return made;
    var ticks: [limits.rows]u64 = undefined;
    for (slots, 0..) |slot, index| ticks[index] = slot.ticks;
    ticks[slots.len] = made.other;
    split(ticks[0 .. slots.len + 1], made.total, &made.shares);
    return made;
}

/// What an owner is called: a thread's name from its control block, an
/// exception's label or IRQ number, or null for idle, `before` and a
/// thread whose name cannot be read.
pub fn ownerName(who: rtos_load.Owner, memory: anytype, buffer: *[names.longest]u8) ?[]const u8 {
    switch (who.kind) {
        .before, .idle => return null,
        .thread => return names.name(memory, who.id, buffer),
        .exception => {
            const number: u16 = @intCast(who.id);
            if (isr.label(number)) |text| return text;
            if (number < 16) return null;
            return std.fmt.bufPrint(buffer, "IRQ{d}", .{number - 16}) catch null;
        },
    }
}

/// One core's load table: the tracer's core, charged up to its clock now.
pub fn load(out: anytype, tracer: ?*const rtos_hook.Tracer, memory: anytype) !void {
    const one = tracer orelse return;
    const made = table(one);
    try out.print("  cpu load cpu{d} : {d} instruction(s)\n", .{ made.core, made.total });
    if (made.total == 0) return;
    for (made.rows(), 0..) |slot, index| {
        try share(out, made.shares[index], slot.ticks);
        try owner(out, slot.owner, memory);
    }
    if (made.other > 0) {
        try share(out, made.shares[made.len], made.other);
        try out.print("other\n", .{});
    }
}

/// Shares of `total` in tenths of a percent, floored, with what flooring
/// lost handed one tenth at a time to the largest remainders, so they add
/// up to exactly `limits.whole`. `ticks` must add up to `total`.
pub fn split(ticks: []const u64, total: u64, into: []u64) void {
    var left: [limits.rows]u64 = undefined;
    var given: u64 = 0;
    for (ticks, 0..) |count, index| {
        const scaled = @as(u128, count) * limits.whole;
        into[index] = @intCast(scaled / total);
        left[index] = @intCast(scaled % total);
        given += into[index];
    }
    while (given < limits.whole) : (given += 1) {
        var best: usize = 0;
        for (ticks, 0..) |_, index| {
            if (left[index] > left[best]) best = index;
        }
        if (left[best] == 0) return;
        into[best] += 1;
        left[best] = 0;
    }
}

fn share(out: anytype, tenths: u64, ticks: u64) !void {
    try out.print("                  {d: >3}.{d}% {d: >10}  ", .{ tenths / 10, tenths % 10, ticks });
}

fn owner(out: anytype, who: rtos_load.Owner, memory: anytype) !void {
    switch (who.kind) {
        .before => try out.print("before the first switch\n", .{}),
        .idle => try out.print("idle\n", .{}),
        .thread => {
            try out.print("0x{X:0>8}", .{who.id});
            var buffer: [names.longest]u8 = undefined;
            if (names.name(memory, who.id, &buffer)) |text| try out.print(" {s}", .{text});
            try out.print("\n", .{});
        },
        .exception => {
            const number: u16 = @intCast(who.id);
            if (isr.label(number)) |text| return out.print("{s}\n", .{text});
            if (number >= 16) return out.print("IRQ{d}\n", .{number - 16});
            try out.print("exception {d}\n", .{number});
        },
    }
}
