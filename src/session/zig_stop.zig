//! The counter `--stop-sym NAME N` names, for a Zig run (RA8EMU-603).
//!
//! Resolved against the image's symbol table. The
//! counter is read at each boundary by the run clock's done check.
const std = @import("std");
const elf = @import("../board/image/elf.zig");
const symbols = @import("symbols.zig");
const Stop = @import("ra8_chip").core.stop.Stop;
const Deadline = @import("ra8_chip").core.deadline.Deadline;

/// The watched counter, or null. A name the image does not carry is
/// reported and the run goes to its instruction budget instead: a missing
/// symbol is the suite's verdict to make, not a reason to refuse the run.
///
/// With `--ns`, a name the main image lacks is looked up in the Non-secure
/// image too, as `--dump-sym` does (RA8EMU-651): a TrustZone build keeps its
/// heartbeat counters on the Non-secure side.
pub fn resolve(image: elf.Image, non_secure: ?elf.Image, wanted: ?[]const u8, reaches: u32) ?Stop {
    const name = wanted orelse return null;
    var images: [2]elf.Image = .{ image, undefined };
    var count: usize = 1;
    if (non_secure) |second| {
        images[1] = second;
        count = 2;
    }
    const address = symbols.addressInAny(images[0..count], name) orelse {
        std.debug.print("--stop-sym {s} not found in symbol table\n", .{name});
        return null;
    };
    return .{ .address = address, .reaches = reaches };
}

/// The modelled-time window `--ms` allows, or none.
pub fn deadline(ms: ?u64) ?Deadline {
    const milliseconds = ms orelse return null;
    return .{ .periods = milliseconds };
}

/// The line saying which of the counter, the deadline or the budget ended
/// the run, worded as src/interfaces/cli/main.zig words it. Nothing is said when neither
/// was asked for: the core's own line already gave the budget.
pub fn verdict(out: anytype, wanted: ?[]const u8, stop: ?Stop, timed: ?Deadline, pc: u32, budget: usize) !void {
    const spent = if (timed) |due| due.reached else false;
    const watched = stop orelse {
        if (spent) try out.print("stopped clean after {d} ms, pc 0x{X:0>8}\n", .{ timed.?.periods, pc });
        return;
    };
    const name = wanted.?;
    if (watched.reached) return out.print("stopped clean on {s} >= {d}, pc 0x{X:0>8}\n", .{ name, watched.reaches, pc });
    if (spent) return out.print("ran {d} ms, {s} never reached {d}, pc 0x{X:0>8}\n", .{ timed.?.periods, name, watched.reaches, pc });
    try out.print("ran {d} instructions, {s} never reached {d}, pc 0x{X:0>8}\n", .{ budget, name, watched.reaches, pc });
}
