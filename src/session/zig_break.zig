//! The address `--break-sym` names, for a Zig run (RA8EMU-603).
//!
//! Resolved against the image's symbol table. Arrivals
//! are counted on each retired instruction; the run ends at the next
//! boundary after the wanted one, and the verdict names that arrival's own
//! address.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const breakpoint = @import("breakpoint.zig");
const pc_hits = @import("pc_hits.zig");
const profile = @import("profile.zig");
const cpu = @import("ra8_chip").core.cpu.cpu;

pub const Break = breakpoint.Break;

/// The break, or null. A place the image does not carry is reported and the
/// run goes to its instruction budget, as `--stop-sym` does.
pub fn resolve(image: elf.Image, place: ?[]const u8, arrival: u32) ?Break {
    const spec = place orelse return null;
    return breakpoint.resolve(image, spec, arrival) catch |err| {
        std.debug.print("--break-sym {s}: {s}\n", .{ spec, @errorName(err) });
        return null;
    };
}

/// What each retired instruction is shown to: the profile table, the break,
/// or both.
pub const Retire = struct {
    table: ?*profile.Table = null,
    point: ?*Break = null,
    /// The `--count-pc` addresses (RA8EMU-951), counted on every retired
    /// instruction.
    hits: ?*pc_hits.Hits = null,
    /// The address of the wanted arrival, once it happened.
    at: u32 = 0,

    /// The core's listener, or null when nothing listens.
    pub fn listener(self: *Retire) ?cpu.RetireListener {
        if (self.table == null and self.point == null and self.hits == null) return null;
        return .{ .context = self, .instructionFn = instructionThunk };
    }

    /// Count an arrival at the break. Counting stops once the wanted one
    /// is met, so the report says the wanted arrival.
    pub fn instruction(self: *Retire, address: u32) void {
        if (self.table) |table| table.instruction(address);
        if (self.hits) |hits| hits.hit(address & ~breakpoint.limits.thumb_bit);
        const point = self.point orelse return;
        if (point.reached) return;
        if (@as(u64, address & ~breakpoint.limits.thumb_bit) != point.watchedAddress()) return;
        if (point.count()) self.at = address;
    }
};

fn instructionThunk(context: *anyopaque, address: u32) void {
    const self: *Retire = @ptrCast(@alignCast(context));
    self.instruction(address);
}

/// The verdict line, worded as src/interfaces/cli/main.zig words it.
pub fn verdict(out: anytype, place: []const u8, point: Break, at: u32, pc: u32, budget: usize) !void {
    if (point.reached) return out.print("reached {s} arrival {d}, pc 0x{X:0>8}\n", .{ place, point.seen, at });
    try out.print("ran {d} instructions, reached {s} {d} time(s) of {d}, pc 0x{X:0>8}\n", .{ budget, place, point.seen, point.arrival, pc });
}
