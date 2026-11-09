//! One core's architectural state in a snapshot (RA8EMU-658): the register
//! file, the banked Secure/Non-secure copies, FP and MVE state, the active
//! exception stack, VTOR, the raised exception, the exclusive monitor, the
//! event register, any WFI/WFE wait and the retired count.
//!
//! Wiring is left as the board built it: the bus, exception source, caches,
//! MPU and attribution hooks, listeners and the profile. Peripheral state
//! outside guest memory is RA8EMU-564's. A successful restore invalidates
//! decode and block caches before execution resumes.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const Cpu = @import("cpu.zig").Cpu;
const Entry = @import("exception/active.zig").Entry;

pub const Error = file.Error || fields.Error || error{Missing};

/// The Cpu fields saved whole, in format order. Appending is a format change.
pub const saved = .{ "regs", "fp", "retired", "vtor", "raised", "exclusive", "banked", "entering_non_secure", "secure_faults", "event", "waiting" };
pub const lifecycle = .{ "slots", "sync_entries", "booted" };

/// A cpu section for `core` (0 for CPU0, 1 for CPU1).
pub fn save(cpu: *const Cpu, core: u8, writer: anytype) !void {
    comptime if (!complete()) @compileError("unclassified Cpu snapshot field");
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(cpu, core, &counter.writer);
    try file.writeSectionHeader(writer, .cpu, counter.fullCount());
    try body(cpu, core, writer);
}

pub fn complete() bool {
    const omitted = .{
        .{ .name = "metrics_epoch", .reason = "Host telemetry generation advances after restore" },
        .{ .name = "idle_cycles", .reason = "Host metrics counter retained across restores" },
        .{ .name = "bus", .reason = "Embedding memory and MMIO wiring" },
        .{ .name = "retire_listener", .reason = "Embedding observer callback" },
        .{ .name = "fetch_guard", .reason = "Embedding guard callback" },
        .{ .name = "source", .reason = "Exception-source wiring; owner saves its NVIC model" },
        .{ .name = "quiet", .reason = "Derived poll cache invalidated after restore" },
        .{ .name = "cut", .reason = "Run-owner SysTick boundary seam" },
        .{ .name = "until", .reason = "Embedding stop policy" },
        .{ .name = "decoded", .reason = "Derived cache invalidated after restore" },
        .{ .name = "blocks", .reason = "Derived cache invalidated after restore" },
        .{ .name = "attribution", .reason = "Stable security-model wiring" },
        .{ .name = "mpu", .reason = "Stable MPU-model wiring" },
        .{ .name = "profile", .reason = "Root part configuration" },
        .{ .name = "trip", .reason = "Derived loop accelerator reset after restore" },
        .{ .name = "event_sender", .reason = "Embedding cross-core event callback retained on the target" },
    };
    return fields.complete(Cpu, saved ++ lifecycle ++ .{"active"}, omitted);
}

fn body(cpu: *const Cpu, core: u8, writer: anytype) !void {
    try fields.write(writer, core);
    inline for (saved) |name| try fields.write(writer, @field(cpu, name));
    inline for (lifecycle) |name| try fields.write(writer, @field(cpu, name));
    // Only the live entries: the rest of the stack is undefined.
    const live = cpu.active.stack[0..cpu.active.depth];
    try fields.write(writer, @as(u8, @intCast(live.len)));
    for (live) |entry| try fields.write(writer, entry);
}

/// Restores `core`'s state from a whole snapshot file. On any error the
/// core is left exactly as it was.
pub fn load(cpu: *Cpu, core: u8, bytes: []const u8) Error!void {
    cpu.* = try prepare(cpu, core, bytes);
    afterRestore(cpu);
}

/// Decode without touching the core or its pointed-to caches.
pub fn prepare(cpu: *const Cpu, core: u8, bytes: []const u8) Error!Cpu {
    var reader = try file.Reader.open(bytes);
    var found: ?Cpu = null;
    while (try reader.next()) |section| {
        if (section.kind != .cpu) continue;
        var cursor: fields.Cursor = .{ .bytes = section.payload };
        if (try fields.read(u8, &cursor) != core) continue;
        if (found != null) return error.DuplicateSection;
        var next = cpu.*;
        try apply(&next, &cursor);
        found = next;
    }
    return found orelse Error.Missing;
}

fn apply(cpu: *Cpu, cursor: *fields.Cursor) Error!void {
    var next = cpu.*;
    inline for (saved) |name| @field(next, name) = try fields.read(@TypeOf(@field(next, name)), cursor);
    inline for (lifecycle) |name| @field(next, name) = try fields.read(@TypeOf(@field(next, name)), cursor);
    if (next.sync_entries > next.slots) return Error.BadValue;
    const depth = try fields.read(u8, cursor);
    if (depth > next.active.stack.len) return Error.BadValue;
    for (next.active.stack[0..depth]) |*entry| entry.* = try fields.read(Entry, cursor);
    next.active.depth = depth;
    if (!cursor.done()) return Error.BadValue;
    cpu.* = next;
}

/// Drop execution accelerators only after the restored state commits.
pub fn afterRestore(cpu: *Cpu) void {
    cpu.metrics_epoch +%= 1;
    if (cpu.blocks) |cache| cache.init();
    if (cpu.decoded) |cache| cache.* = .{};
    cpu.trip = .{};
    if (cpu.quiet) |quiet| quiet.stirAll();
}
