//! `--stop-on-undefined` on a Zig run: the sites the undefined-instruction
//! sweep found (src/chip/core/undefined_ops.zig), counted as the core reaches
//! them, and the run ended at the first one, before it executes.
//!
//! The core asks a fetch guard (src/chip/core/cpu/fetch_guard.zig) before every
//! instruction. The guard is only installed when the flag asks for it,
//! because it turns off the trip skipping a plain run relies on.
const elf = @import("../image/elf.zig");
const undefined_ops = @import("ra8_chip").core.undefined_ops;
const read_image = @import("../image/load.zig");
const cpu = @import("ra8_chip").core.cpu.cpu;

pub const Found = undefined_ops.Found;

/// The swept sites, each asked to end the run, or none without the flag.
pub fn resolve(image: elf.Image, wanted: bool) ?Found {
    if (!wanted) return null;
    const loaded = read_image.read(image) catch return null;
    var found = undefined_ops.sweep(loaded.image());
    found.stopOnRun();
    return found;
}

/// Count an arrival at `address` and say whether it ends the run.
pub fn arrive(found: *Found, address: u32) bool {
    const at = address & ~@as(u32, 1);
    for (found.kept()) |*site| {
        if (site.address != at) continue;
        site.runs += 1;
        return site.stop;
    }
    return false;
}

/// The guard the core asks before each instruction, or none when the sweep
/// found nothing, so an image without sites keeps its fast loop.
pub fn guard(found: *Found) ?cpu.FetchGuard {
    if (found.count == 0) return null;
    return .{ .context = found, .holdsFn = holdsThunk };
}

fn holdsThunk(context: *anyopaque, address: u32) bool {
    const found: *Found = @ptrCast(@alignCast(context));
    return arrive(found, address);
}
