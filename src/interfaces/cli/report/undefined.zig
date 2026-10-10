//! The `--stop-on-undefined` lines of a Zig run's report: what the
//! undefined-instruction sweep (src/chip/core/undefined_ops.zig) found, each site
//! named by the function it sits in, and what the run did with them.
//!
//! The chip only records the sites: address, encoding, arrivals. Naming
//! them from the symbol table is the frontend's job, so it lives here.
const elf = @import("ra8_board").image.elf;
const undefined_ops = @import("ra8_chip").core.undefined_ops;
const symbols = @import("../../../session/symbols.zig");

const Found = undefined_ops.Found;
const limits = undefined_ops.limits;

/// Say what the sweep found, or nothing at all when it found nothing.
///
/// Each site carries the function it sits in, because an address alone
/// sends the reader to objdump to learn the one thing they will ask first.
/// An image with no symbol table, or an address no sized function symbol
/// covers, prints the address by itself rather than a guess.
pub fn print(out: anytype, image: elf.Image, found: Found) !void {
    if (found.count == 0) return;
    try out.print(
        "  undefined     : {d} site(s) name pc as a shifted operand, UNPREDICTABLE\n",
        .{found.count},
    );
    for (found.listed()) |site| {
        try out.print("                  0x{X:0>8} {X:0>8}", .{ site.address, site.encoding });
        if (symbols.inside(image, site.address)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        if (site.runs > 0) try out.print(" EXECUTED {d}x", .{site.runs});
        try out.print("\n", .{});
    }
    if (found.count > limits.listed) {
        try out.print("                  and {d} more\n", .{found.count - limits.listed});
        try executedPastTheList(out, image, found);
    }
    try ran(out, found);
    try stoppedThere(out, image, found);
}

/// Name the site the run stopped on, when one did.
///
/// This matters more than it looks: with `--stop-on-undefined` the run
/// ends BEFORE the undefined instruction executes, so every register and
/// every word of memory a dump prints afterwards is the machine as it
/// stood on the way in. Without this line a short run reads like a crash
/// or a budget that ran out, and the dumps beside it read like the state
/// after the damage rather than before it.
fn stoppedThere(out: anytype, image: elf.Image, found: Found) !void {
    const site = found.stoppedAt() orelse return;
    try out.print("                  run stopped at 0x{X:0>8}", .{site.address});
    if (symbols.inside(image, site.address)) |at| {
        try out.print(" {s}+0x{X}", .{ at.name, at.offset });
    }
    try out.print(", before it executed\n", .{});
}

/// Name any site that ran but sat past the end of the list.
///
/// Without this the report can say one site executed while marking none of
/// the six it listed, which sends the reader looking for a contradiction
/// that is really just a list cap. A site that ran is the one a reader
/// actually wants, so it is named wherever it sits.
fn executedPastTheList(out: anytype, image: elf.Image, found: Found) !void {
    var index: usize = limits.listed;
    while (index < @min(found.count, limits.watched)) : (index += 1) {
        const site = found.sites[index];
        if (site.runs == 0) continue;
        try out.print("                  0x{X:0>8} {X:0>8}", .{ site.address, site.encoding });
        if (symbols.inside(image, site.address)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print(" EXECUTED {d}x\n", .{site.runs});
    }
}

/// What the run did with what the sweep found.
///
/// The negative is worth printing too: an image carrying these encodings
/// that never reaches one is an image whose results are its own, and
/// saying so is what stops the sweep reading as an accusation. A run that
/// did reach one is named loudly, because every sector number, length and
/// offset computed after it is arithmetic on a program counter.
fn ran(out: anytype, found: Found) !void {
    const sites = found.sitesRun();
    if (sites == 0) {
        try out.print("                  none executed, results downstream are the image's own\n", .{});
        return;
    }
    try out.print(
        "                  {d} of them EXECUTED, {d} arrival(s): results downstream are not trustworthy\n",
        .{ sites, found.arrivals() },
    );
    if (found.count > limits.watched) {
        try out.print(
            "                  {d} site(s) past the watch limit went uncounted\n",
            .{found.count - limits.watched},
        );
    }
}
