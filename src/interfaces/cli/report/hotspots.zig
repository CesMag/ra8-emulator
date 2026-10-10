//! Where the run spent itself.
//!
//! Elapsed cycles say how far a run got, never where it went. A run that
//! covered four billion cycles inside one six-instruction spin and a run
//! that did four billion cycles of work print the same time line, and the
//! only way to tell them apart was a throwaway print or a watchpoint on a
//! word the spin happened to touch. This is that difference, printed.
//!
//! Sampled, not counted, and the wording says so: one program counter per
//! chunk boundary is coarse enough that a share is a share of the
//! BOUNDARIES, not of the instructions. It separates a spin from work,
//! which is the question actually being asked, and it is not a profiler.
//!
//! Quiet when the run spread itself out. A working image touches too many
//! addresses for any one of them to reach the floor, so it prints nothing
//! and the reader learns that by the absence.
const hotspots = @import("../../../session/hotspots.zig");
const functions = @import("../../../session/functions.zig");
const symbols = @import("../../../session/symbols.zig");
const elf = @import("../../../board/image/elf.zig");
const Writer = @import("../report.zig").Writer;

/// Print the addresses the run kept coming back to, most sampled first.
///
/// The symbol is looked up per site rather than carried on the sample: the
/// table is written to on a hot path and the image is only needed here.
pub fn spent(out: Writer, image: elf.Image, table: hotspots.Table) !void {
    if (table.quiet()) return;
    var into: [hotspots.limits.kept]hotspots.Site = undefined;
    const ranked = table.ranked(&into);

    var listed: usize = 0;
    for (ranked) |site| {
        if (listed >= hotspots.limits.listed) break;
        const share = table.shareOf(site);
        if (share < hotspots.limits.floor_percent) break;
        listed += 1;
        try out.print(
            "where: {d}% of {d} boundary sample(s) at pc 0x{X:0>8}",
            .{ share, table.total, site.address },
        );
        if (symbols.inside(image, site.address)) |found| {
            try out.print(" ({s}+0x{X})", .{ found.name, found.offset });
        }
        try out.print("\n", .{});
    }
    if (table.displaced > 0) {
        try out.print(
            "where: {d} other address(es) did not stay in the table; the run was not only here\n",
            .{table.displaced},
        );
    }
}

/// Print the functions the run kept coming back to, most sampled first.
///
/// Printed after `spent` and in the same shape, because it answers the
/// same question one step coarser: `spent` says which instruction a spin
/// sits on, this says which function burned the run. On anything that is
/// doing work the pc table churns and this one does not.
pub fn spentIn(out: Writer, image: elf.Image, table: functions.Table) !void {
    if (table.sites.quiet()) return;
    var into: [hotspots.limits.kept]hotspots.Site = undefined;
    const ranked = table.sites.ranked(&into);

    var listed: usize = 0;
    for (ranked) |site| {
        if (listed >= hotspots.limits.listed) break;
        const share = table.sites.shareOf(site);
        if (share < hotspots.limits.floor_percent) break;
        listed += 1;
        try out.print("where: {d}% of {d} boundary sample(s) in ", .{ share, table.sites.total });
        if (symbols.inside(image, site.address)) |found| {
            try out.print("{s}\n", .{found.name});
        } else {
            try out.print("unnamed code at 0x{X:0>8}\n", .{site.address});
        }
    }
    if (table.sites.displaced > 0) {
        try out.print(
            "where: {d} other function(s) did not stay in the table\n",
            .{table.sites.displaced},
        );
    }
}
