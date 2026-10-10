//! The text a finished run prints after the report block: where the
//! run spent itself, then the site lines. `--report json` carries all of it
//! in the one JSON line (RA8EMU-391), so main.zig calls this only for text.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const cli = @import("../cli.zig");
const Parts = @import("../parts.zig").Parts;
const taken_in = @import("ra8_session").taken_in;
const report_hotspots = @import("hotspots.zig");
const profile = @import("profile.zig");
const report_timing = @import("timing.zig");

/// In the order main.zig printed these lines before they moved here.
pub fn text(out: anytype, io: std.Io, image: elf.Image, options: cli.Options, parts: Parts, window: ?taken_in.Window) !void {
    try report_hotspots.spent(out, image, parts.pcs);
    try report_hotspots.spentIn(out, image, parts.fns.?);
    if (parts.profile) |table| try profile.write(out, io, image, table, options.profile_folded);
    try report_timing.pcHits(out, image, parts.hits);
    try report_timing.takenFrom(out, image, parts.taken);
    try report_timing.takenIn(out, image, options.taken_in_place, window);
}
