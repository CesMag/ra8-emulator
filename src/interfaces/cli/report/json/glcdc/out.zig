//! The second half of the `glcdc` object of `--report json` (RA8EMU-366):
//! how the two graphics layers reached the panel, the scan of what it
//! shows, the output stage on the panel bus and the system control block,
//! the same facts report/graphics.zig and report/glcdc_sys.zig print. Every
//! key is always present; `layers` holds only the layers that blended.

/// The layers, mixer, scan, output and system keys inside `glcdc`.
pub fn parts(j: anytype, unit: anytype) !void {
    try layers(j, unit);
    try j.open("mixer", '{');
    try j.field("mixes", unit.mixer.mixes);
    try j.field("overlapped", unit.mixer.overlapped);
    try j.field("background", unit.mixer.bare);
    try j.close('}');
    try scan(j, unit);
    try output(j, unit);
    try system(j, unit);
}

fn layers(j: anytype, unit: anytype) !void {
    try j.open("layers", '[');
    for (&unit.blends, 1..) |*stage, layer| {
        if (stage.quiet()) continue;
        const rect = stage.rect();
        try j.open(null, '{');
        try j.field("layer", layer);
        try j.field("display", @tagName(stage.display()));
        try j.field("width", rect.width);
        try j.field("height", rect.height);
        try j.field("left", rect.left);
        try j.field("top", rect.top);
        try j.field("shown", stage.shown);
        try j.field("held_back", stage.hidden);
        try j.field("chroma_keyed", stage.keyed);
        try j.close('}');
    }
    try j.close(']');
}

fn scan(j: anytype, unit: anytype) !void {
    const scanner = &unit.scanner;
    try j.open("scan", '{');
    if (scanner.last) |picture| {
        try j.open("picture", '{');
        try j.field("pixels", picture.pixels);
        try j.field("colours", picture.colours);
        try j.field("transparent", picture.blank);
        try j.field("content_hash", picture.hash);
        try j.close('}');
    } else try j.field("picture", null);
    try j.field("refused_no_palette", scanner.count(.no_palette));
    try j.field("refused_off_ram", scanner.count(.off_ram));
    try j.field("refused_too_big", scanner.count(.too_big));
    try j.field("output_off", scanner.count(.output_off));
    try j.field("faults", scanner.count(.fault));
    try j.close('}');
}

fn output(j: anytype, unit: anytype) !void {
    const stage = &unit.output;
    try j.open("output", '{');
    try j.field("bus", @tagName(stage.live.format()));
    try j.field("dither", @tagName(stage.live.dither()));
    try j.field("gamma", stage.gamma_on);
    try j.field("pixels", stage.pixels);
    try j.field("narrowed", stage.narrowed);
    try j.field("dithered", stage.dithered);
    try j.field("gamma_corrected", stage.corrected);
    try j.field("clipped", stage.clipped);
    try j.field("uncommitted", stage.pending());
    try j.close('}');
}

fn system(j: anytype, unit: anytype) !void {
    const sys = &unit.system;
    try j.open("system", '{');
    try j.field("clocked", sys.clocked());
    try j.field("source", if (sys.clocked()) sys.source().name() else null);
    try j.field("divider", if (sys.clocked()) sys.divider() else null);
    try j.field("frames", sys.frames);
    try j.field("refused_unclocked", sys.unclocked);
    try j.field("stmon", sys.status);
    try j.field("armed", sys.detect);
    try j.field("enabled", sys.interrupts);
    try j.field("detections", sys.detections);
    try j.field("would_pend", sys.interrupts_due);
    try j.field("undetected", sys.undetected);
    try j.field("underflows", sys.underflows);
    try j.field("stale_clears", sys.stale_clears);
    try j.field("refused_stmon_writes", sys.status_writes);
    try j.close('}');
}
