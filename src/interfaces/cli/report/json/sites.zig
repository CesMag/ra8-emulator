//! The `sites` object of `--report json` (RA8EMU-382): the addresses behind
//! the counters, the same facts report/timing.zig prints in pcHits(),
//! takenFrom() and takenIn().
//! Every kept row is listed, ranked as the text ranks it, each with the
//! symbol around it; the text's top-N cut on taken-from is not applied.
//! Nothing feeds it on the Zig core, so it is null.
const elf = @import("ra8_board").image.elf;
const pc_hits = @import("ra8_session").pc_hits;
const tally_mod = @import("ra8_session").tally;
const taken_in = @import("ra8_session").taken_in;
const symbol = @import("where.zig").symbol;

/// The run's site tables, borrowed from the report Tally.
pub const Sites = struct {
    image: ?elf.Image = null,
    hits: ?*const pc_hits.Hits = null,
    taken: ?*const tally_mod.Tally = null,
    /// What `--taken-in` named, and the window it resolved to.
    taken_in_spec: ?[]const u8 = null,
    taken_in: ?*const taken_in.Window = null,
};

/// The `sites` object, or null when the run collected none of it.
pub fn section(j: anytype, found: ?*const Sites) !void {
    const of = found orelse return j.field("sites", null);
    try j.open("sites", '{');
    try hitsOf(j, of.image, of.hits);
    try takenFrom(j, of.image, of.taken);
    try takenIn(j, of.image, of.taken_in_spec, of.taken_in);
    try j.close('}');
}

fn hitsOf(j: anytype, image: ?elf.Image, found: ?*const pc_hits.Hits) !void {
    const hits = found orelse return j.field("pc_hits", null);
    try j.open("pc_hits", '{');
    try j.open("counted", '[');
    for (hits.asked()) |one| {
        try j.open(null, '{');
        try j.field("pc", one.at);
        try j.field("hits", one.hits);
        try symbol(j, image, one.at);
        try j.close('}');
    }
    try j.close(']');
    try j.field("refused", hits.refused);
    try j.close('}');
}

fn takenFrom(j: anytype, image: ?elf.Image, found: ?*const tally_mod.Tally) !void {
    const counted = found orelse return j.field("taken_from", null);
    try j.open("taken_from", '{');
    try j.open("sites", '[');
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    for (counted.ranked(&room)) |site| {
        try j.open(null, '{');
        try j.field("exception", site.value);
        try j.field("pc", site.pc);
        try j.field("entries", site.writes);
        try symbol(j, image, site.pc);
        try j.close('}');
    }
    try j.close(']');
    try j.field("displaced", counted.displaced);
    try j.close('}');
}

/// Null unless `--taken-in` named a function the image resolves.
fn takenIn(j: anytype, image: ?elf.Image, spec: ?[]const u8, found: ?*const taken_in.Window) !void {
    const asked = spec orelse return j.field("taken_in", null);
    const one = found orelse return j.field("taken_in", null);
    try j.open("taken_in", '{');
    try j.field("function", asked);
    try j.field("base", one.base);
    try j.field("size", one.size);
    try j.field("seen", one.seen);
    try j.open("kept", '[');
    for (one.kept()) |entry| {
        try j.open(null, '{');
        try j.field("n", entry.at);
        try j.field("exception", entry.number);
        try j.field("pc", entry.pc);
        try symbol(j, image, entry.pc);
        try j.close('}');
    }
    try j.close(']');
    try j.field("missed", one.missed());
    try j.close('}');
}
