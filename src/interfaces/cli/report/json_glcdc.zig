//! The `graphics` object of `--report json` (RA8EMU-366): the graphics
//! power domain and the GLCDC display controller (the framebuffer it
//! fetches, its palettes, the panel timing and pin routing), the same facts
//! report/graphics.zig prints. The layers, the mixer, the scan, the output
//! stage and the system block follow in json_glcdc_out.zig;
//! the drawing engine and the e-ink panel in json_drw.zig (RA8EMU-371). Every key is
//! always present; lists hold only the entries the firmware programmed.
const Board = @import("ra8_board").board.Board;
const json_glcdc_out = @import("json_glcdc_out.zig");
const json_drw = @import("json_drw.zig");

/// The whole `graphics` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    const unit = &board.display;
    // The run has ended, so what the drawing engine left in the framebuffer
    // is what the panel shows: scan it now, as the human report does.
    if (!unit.quiet()) _ = unit.scanOut();
    try j.open("graphics", '{');
    try domain(j, board);
    try j.open("glcdc", '{');
    try j.field("writes", unit.writes);
    try j.field("vblank_updates", unit.updates());
    try j.field("dropped_unpowered", unit.dropped_unpowered);
    try j.field("dark_reads", unit.dark_reads);
    try framebuffer(j, unit);
    try palettes(j, unit);
    try timing(j, unit);
    try json_glcdc_out.parts(j, unit);
    try j.close('}');
    try json_drw.parts(j, board);
    try j.close('}');
}

fn domain(j: anytype, board: *Board) !void {
    const unit = &board.domains.graphics;
    try j.open("domain", '{');
    try j.field("powered", unit.powered());
    try j.field("power_ons", unit.power_ons);
    try j.field("power_offs", unit.power_offs);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.close('}');
}

fn framebuffer(j: anytype, unit: anytype) !void {
    const frame = unit.framebuffer() orelse return j.field("framebuffer", null);
    try j.open("framebuffer", '{');
    try j.field("layer", frame.layer);
    try j.field("base", frame.base);
    try j.field("width", frame.width);
    try j.field("height", frame.height);
    try j.field("stride", frame.stride);
    try j.field("format", @tagName(frame.format));
    try j.field("output_enabled", frame.enabled);
    try j.close('}');
}

fn palettes(j: anytype, unit: anytype) !void {
    try j.open("palettes", '[');
    for (&unit.palettes, 1..) |*palette, layer| {
        if (palette.quiet()) continue;
        try j.open(null, '{');
        try j.field("layer", layer);
        try j.field("plane0_entries", palette.filled[0]);
        try j.field("plane1_entries", palette.filled[1]);
        try j.field("selected_plane", palette.selected);
        try j.close('}');
    }
    try j.close(']');
}

fn timing(j: anytype, unit: anytype) !void {
    try j.open("timing", '{');
    try j.field("tcon_writes", unit.timing.writes);
    if (unit.timing.timing()) |found| {
        try j.open("panel", '{');
        try j.field("h_active", found.h_active);
        try j.field("v_active", found.v_active);
        try j.field("h_sync", found.h_sync);
        try j.field("h_back", found.h_back);
        try j.field("v_sync", found.v_sync);
        try j.field("v_back", found.v_back);
        try j.close('}');
    } else try j.field("panel", null);
    const clipped = if (unit.framebuffer()) |frame| !unit.timing.contains(frame.width, frame.height) else false;
    try j.field("layer_clipped", unit.timing.timing() != null and clipped);
    try j.open("pins", '[');
    for (unit.timing.pin, 0..) |one, index| {
        if (!one.programmed) continue;
        try j.open(null, '{');
        try j.field("tcon", index);
        try j.field("signal", one.signal.name());
        try j.field("inverted", one.inverted);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}
