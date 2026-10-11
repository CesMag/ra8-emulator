//! The panel mixer: the background colour, the graphics layers stacked on
//! it, and what a viewer ends up seeing.
//!
//! One framebuffer is not a panel. The block composites the background
//! plane, then graphics 1, then graphics 2 on top of it, each layer sitting
//! in its own rectangle and reaching the panel only as far as its AB1
//! DISPSEL, its chroma key and its alpha allow. dev picks a single layer and
//! hashes it: GR1 when GR1.FLMRD is set, GR2 otherwise. An overlay over a
//! background image, which is the whole reason there are two layers, has
//! never been in a witness from that tree at all.
const std = @import("std");
const Guest = @import("../../core/cpu/memory/guest/guest.zig").Guest;
const clut = @import("clut.zig");
const scan = @import("scan.zig");
const blend = @import("blend.zig");
const output = @import("out.zig");

/// How many layers stack on the panel.
pub const layers: u32 = 2;

/// The panel the layers are composited onto.
pub const Panel = struct {
    width: u32,
    height: u32,
    /// BG.BGC, shown wherever no layer reaches the panel.
    background: u32,
    /// The output stage the composited pixel leaves through, or null on a
    /// mix that only cares about what the layers put together.
    stage: ?*output.Stage = null,
};

/// One layer as the mixer sees it: where its pixels come from, the palette
/// they are looked up in, and the blend stage in front of them.
pub const Plane = struct {
    shape: scan.Shape,
    palette: *const clut.Palette,
    stage: *blend.Layer,
};

/// A mix either produced the panel or refused, for one of the reasons a
/// single-framebuffer scan refuses.
pub const Result = union(enum) {
    picture: scan.Picture,
    refused: scan.Refusal,
};

/// The compositor. Counters here are about the panel as a whole; what each
/// layer contributed is counted on the layer's own blend stage.
pub const Mixer = struct {
    /// Panels composited.
    mixes: u32 = 0,
    /// Pixels where more than one layer reached the panel.
    overlapped: u32 = 0,
    /// Pixels where no layer did, so the background colour shows.
    bare: u32 = 0,

    pub fn quiet(self: *const Mixer) bool {
        return self.mixes == 0;
    }

    /// Composite the panel. Planes are bottom first, so graphics 1 then
    /// graphics 2, which is the order the block stacks them in.
    pub fn run(self: *Mixer, memory: Guest, panel: Panel, planes: []const Plane) Result {
        for (planes) |plane| {
            if (scan.validate(plane.shape, plane.palette)) |why| return .{ .refused = why };
        }
        var fold = scan.Fold{};
        var lines: [layers][scan.limits.chunk]u8 = undefined;
        var at: u32 = 0;
        while (at < panel.height) : (at += 1) {
            var fetched: [layers]?[]const u8 = .{ null, null };
            for (planes, 0..) |plane, index| {
                fetched[index] = readRow(memory, plane, at, &lines[index]) catch {
                    return .{ .refused = .fault };
                };
            }
            self.row(&fold, panel, planes, fetched, at);
        }
        self.mixes += 1;
        return .{ .picture = fold.picture() };
    }

    /// One panel row, left to right.
    fn row(
        self: *Mixer,
        fold: *scan.Fold,
        panel: Panel,
        planes: []const Plane,
        fetched: [layers]?[]const u8,
        at: u32,
    ) void {
        var column: u32 = 0;
        while (column < panel.width) : (column += 1) {
            var colour = blend.opaqueColour(panel.background);
            var reached: u32 = 0;
            for (planes, 0..) |plane, index| {
                const source = sample(plane, fetched[index], column, at);
                const shown = plane.stage.contribution(source, column, at) orelse continue;
                colour = blend.over(shown, colour);
                reached += 1;
            }
            if (reached == 0) self.bare += 1;
            if (reached > 1) self.overlapped += 1;
            // What the panel receives is what leaves the output stage, not
            // what the mixer put together.
            if (panel.stage) |stage| colour = stage.apply(colour, column, at);
            fold.pixel(colour);
        }
    }
};

/// The bytes of the framebuffer line under one panel row, or null when the
/// layer's rectangle does not reach that row.
fn readRow(
    memory: Guest,
    plane: Plane,
    at: u32,
    into: []u8,
) !?[]const u8 {
    const rect = plane.stage.rect();
    if (at < rect.top or at >= rect.top + rect.height) return null;
    const line = at - rect.top;
    if (line >= plane.shape.height) return null;
    const wanted = plane.shape.lineBytes();
    if (wanted > into.len) return null;
    try memory.read(plane.shape.base + line * plane.shape.stride, into[0..wanted]);
    return into[0..wanted];
}

/// The colour one layer's framebuffer holds under a panel coordinate, or
/// null where the layer has no pixel there.
fn sample(plane: Plane, line: ?[]const u8, column: u32, at: u32) ?u32 {
    _ = at;
    const bytes = line orelse return null;
    const rect = plane.stage.rect();
    if (column < rect.left) return null;
    const local = column - rect.left;
    if (local >= plane.shape.width) return null;
    const raw = scan.fetch(bytes, local, plane.shape.bits);
    return plane.shape.decode(raw, plane.palette);
}
