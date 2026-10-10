//! The `steps`, `hotspots`, `functions` and `profile` objects of
//! `--report json` (RA8EMU-378): what the CPU model could not decode and
//! this emulator stepped by hand, where the run spent itself by sampled pc
//! and by function, and the per-function instruction and cycle counts, the
//! same facts report/hotspots.zig and profile.zig print. These
//! read the run's own tables, not the board, so each is null when that run
//! did not collect it (the Zig core feeds no step or sample hooks, and the
//! profile exists only under --profile).
const elf = @import("../../../image/elf.zig");
const symbols = @import("../../../session/symbols.zig");
const hotspots = @import("../../../session/hotspots.zig");

/// The sampled-pc table type, so tests can build one.
pub const Pcs = hotspots.Table;
const functions = @import("../../../session/functions.zig");
const profile = functions.profile;
const lob = @import("ra8_chip").core.lob;
const csel = @import("ra8_chip").core.csel;
const tz = @import("ra8_chip").core.tz;

/// The hand-stepped counts.
pub const Steps = struct {
    loops: lob.Loops,
    selects: csel.Selects,
    worlds: tz.Worlds,
};

/// What the run collected, each null when it collected nothing of the kind.
pub const Where = struct {
    image: ?elf.Image = null,
    steps: ?Steps = null,
    pcs: ?*const hotspots.Table = null,
    fns: ?*const functions.Table = null,
    profile: ?*const profile.Table = null,
};

/// The four objects, keyed inside the document after `compute`.
pub fn section(j: anytype, of: Where) !void {
    try steps(j, of.steps);
    try sampled(j, "hotspots", of.image, if (of.pcs) |table| table.* else null, null);
    if (of.fns) |table| {
        try sampled(j, "functions", of.image, table.sites, table.unnamed);
    } else try j.field("functions", null);
    try profiled(j, of.image, of.profile);
}

fn steps(j: anytype, found: ?Steps) !void {
    const of = found orelse return j.field("steps", null);
    try j.open("steps", '{');
    try j.field("loops_stepped", of.loops.stepped);
    try j.field("selects_stepped", of.selects.stepped);
    try j.open("trustzone", '{');
    try j.field("armed_at", if (of.worlds.quiet()) null else of.worlds.armed_at);
    try j.field("entered", of.worlds.entered());
    try j.field("entered_at", if (of.worlds.entered()) of.worlds.entered_at else null);
    try j.field("stack", if (of.worlds.entered()) of.worlds.stack else null);
    try j.field("switches", of.worlds.switched);
    try j.close('}');
    try j.close('}');
}

/// A sampled table, every kept site ranked, each with its share and the
/// symbol around it. `unnamed` is the functions table's own count.
fn sampled(j: anytype, key: []const u8, image: ?elf.Image, found: ?hotspots.Table, unnamed: ?u64) !void {
    const table = found orelse return j.field(key, null);
    try j.open(key, '{');
    try j.field("samples", table.total);
    try j.field("displaced", table.displaced);
    if (unnamed) |count| try j.field("unnamed", count);
    try j.open("sites", '[');
    var into: [hotspots.limits.kept]hotspots.Site = undefined;
    for (table.ranked(&into)) |site| {
        try j.open(null, '{');
        try j.field("pc", site.address);
        try j.field("samples", site.samples);
        try j.field("share_percent", table.shareOf(site));
        try symbol(j, image, site.address);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

fn profiled(j: anytype, image: ?elf.Image, found: ?*const profile.Table) !void {
    const table = found orelse return j.field("profile", null);
    try j.open("profile", '{');
    try j.field("missed", table.missed);
    try j.open("functions", '[');
    var rows: [profile.limits.functions]profile.Site = undefined;
    for (table.ranked(&rows)) |site| {
        try j.open(null, '{');
        try j.field("address", site.address);
        try j.field("cycles", site.cycles);
        try j.field("instructions", site.instructions);
        try symbol(j, image, site.address);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

/// The symbol around `address` and the offset into it, both null when none.
pub fn symbol(j: anytype, image: ?elf.Image, address: u32) !void {
    const found = if (image) |loaded| symbols.inside(loaded, address) else null;
    try j.field("symbol", if (found) |at| at.name else null);
    try j.field("offset", if (found) |at| at.offset else null);
}
