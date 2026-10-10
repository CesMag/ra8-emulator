//! The graphics story of a run: the power domain the blocks live in, the
//! panel the display controller is scanning, and what the drawing engine put
//! in the framebuffer. Split out of report.zig, which was at the file-length
//! limit, and they belong together anyway: all three read the same domain.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;
const system = @import("glcdc_sys.zig");

/// The three in the order a person reads them: what is powered, what the
/// panel shows, what drew it.
pub fn sections(board: *Board, out: Writer) !void {
    try domain(board, out);
    try display(board, out);
    try raster(board, out);
    try panel(board, out);
}

/// The other display path: the e-paper panel on the SPI line. A command
/// sent to a sleeping panel, a stream longer than the rectangle it declared,
/// a drain past the end of the device-info block, a write to a register the
/// controller owns, and a data word with no command behind it are all things
/// dev let pass, so each is reported apart from the pixels that landed.
pub fn panel(board: *Board, out: Writer) !void {
    const unit = &board.panel;
    if (unit.quiet()) return;
    try out.print(
        "IT8951 e-ink: {d} command(s), {d} pixel(s) loaded, {d} refresh(es), last waveform 0x{X}, VCOM {d}mV, {s}\n",
        .{
            unit.commands,
            unit.pixels,
            unit.refreshes,
            unit.last_waveform,
            unit.vcom_mv,
            if (unit.awake) "awake" else "ASLEEP",
        },
    );
    if (unit.asleep != 0) {
        try out.print(
            "IT8951 e-ink: REFUSED {d} command(s) with the panel asleep (wake it with SYS_RUN first)\n",
            .{unit.asleep},
        );
    }
    if (unit.overrun != 0) {
        try out.print(
            "IT8951 e-ink: REFUSED {d} pixel word(s) past the {d}x{d} rectangle the load declared\n",
            .{ unit.overrun, unit.load_width, unit.load_height },
        );
    }
    try film(unit, out);
    if (unit.overdrain != 0 or unit.stray != 0 or unit.read_only != 0 or unit.spilled != 0) {
        try out.print(
            "IT8951 e-ink: {d} read(s) past the device-info block, {d} data word(s) with no command, {d} write(s) to LUTAFSR, {d} register write(s) dropped\n",
            .{ unit.overdrain, unit.stray, unit.read_only, unit.spilled },
        );
    }
}

/// The film, which dev has no notion of at all. LUTAFSR read zero here too,
/// so every refresh was over the instant it was asked for: a driver's wait
/// loop exited on its first pass and a second refresh clocked in on top of
/// one still being driven looked like two clean ones. The dwell is counted
/// in host polls, not wall time; see components/eink_it8951/busy.zig.
fn film(unit: anytype, out: Writer) !void {
    const lut = &unit.film;
    if (lut.quiet()) return;
    try out.print(
        "IT8951 film: {d} refresh(es), {d} settled, {d} busy poll(s), {d} idle poll(s)\n",
        .{ lut.started, lut.settled, lut.waited, lut.cleared },
    );
    if (lut.unsettled() != 0) {
        try out.print(
            "IT8951 film: {d} refresh(es) never polled out to idle (the image was left mid-refresh)\n",
            .{lut.unsettled()},
        );
    }
    if (lut.overlapped != 0) {
        try out.print(
            "IT8951 film: {d} command(s) arrived with the film still being driven (poll LUTAFSR to idle first)\n",
            .{lut.overlapped},
        );
    }
}

/// What the panel is being scanned from, and the loud case behind it: the
/// graphics power domain is gated off at reset, so a display controller
/// programmed before PDCTRGD is cleared reaches no register at all. dev
/// shadows those writes whatever the domain is doing, so the descriptor
/// looks right there and the panel is dark on the bench.
pub fn display(board: *Board, out: Writer) !void {
    const unit = &board.display;
    if (unit.quiet()) return;
    // The run has ended, so whatever the drawing engine left in the
    // framebuffer is what the panel is showing: scan it now.
    _ = unit.scanOut();
    if (unit.framebuffer()) |frame| {
        try out.print(
            "GLCDC: GR{d} scanning 0x{X:0>8}, {d}x{d}, stride {d}, {s}, output stage {s}\n",
            .{
                frame.layer,
                frame.base,
                frame.width,
                frame.height,
                frame.stride,
                @tagName(frame.format),
                if (frame.enabled) "on" else "OFF (BG_EN.EN clear, panel blank)",
            },
        );
    } else {
        try out.print("GLCDC: {d} write(s), no layer fetching a framebuffer\n", .{unit.writes});
    }
    if (unit.updates() != 0) {
        try out.print(
            "GLCDC: {d} register update(s) latched by a VEN command (the bit is spent on the write, so the driver's vblank poll finishes)\n",
            .{unit.updates()},
        );
    }
    try palettes(unit, out);
    try panelTiming(unit, out);
    try composited(unit, out);
    try scanned(unit, out);
    try outputStage(unit, out);
    try system.sections(unit, out);
    if (unit.dropped_unpowered == 0 and unit.dark_reads == 0) return;
    try out.print(
        "GLCDC: DROPPED {d} write(s) and {d} read(s) with the graphics domain gated off (clear PDCTRGD.PDDE first)\n",
        .{ unit.dropped_unpowered, unit.dark_reads },
    );
}

/// The panel's own timing, which nothing in the C tree reads: dev snoops
/// eleven GLCDC offsets and none of them are in the TCON block, so the
/// active area the driver wrote out of the board's panel table, the sync
/// widths and the pin routing all went into a shadow word. A layer bigger
/// than the active area is clipped by the glass on silicon, so it is said
/// here rather than scanned out whole and called the panel.
fn panelTiming(unit: anytype, out: Writer) !void {
    const found = unit.timing.timing() orelse {
        if (unit.timing.quiet()) return;
        try out.print(
            "GLCDC timing: {d} TCON write(s), no active area (STHB1/STVB1 never programmed)\n",
            .{unit.timing.writes},
        );
        return;
    };
    try out.print(
        "GLCDC timing: panel {d}x{d}, hsync {d} + back {d}, vsync {d} + back {d}\n",
        .{ found.h_active, found.v_active, found.h_sync, found.h_back, found.v_sync, found.v_back },
    );
    try pinning(unit, out);
    if (unit.framebuffer()) |frame| {
        if (!unit.timing.contains(frame.width, frame.height)) {
            try out.print(
                "GLCDC timing: GR{d} is {d}x{d}, past the {d}x{d} active area (the panel clips it)\n",
                .{ frame.layer, frame.width, frame.height, found.h_active, found.v_active },
            );
        }
    }
}

/// Which LCD_TCON pin carries which sync signal, and whether it leaves
/// inverted. A panel wired for the other polarity still hashes a picture
/// here, so the routing is worth reading back.
fn pinning(unit: anytype, out: Writer) !void {
    for (unit.timing.pin, 0..) |one, index| {
        if (!one.programmed) continue;
        try out.print("GLCDC timing: LCD_TCON{d} carries {s}{s}\n", .{
            index,
            one.signal.name(),
            if (one.inverted) " (inverted)" else "",
        });
    }
}

/// What the panel actually shows, which dev stops one step short of. dev
/// folds a hash over the raw framebuffer bytes: a CLUT layer is hashed as
/// index bytes, so the palette a driver spent its init writing is not in the
/// witness and a run with no palette hashes the same as a run with one.
/// Here the pixels are decoded through the format and the layer's palette
/// first, and the cases that are not a picture are said out loud.
fn scanned(unit: anytype, out: Writer) !void {
    const panel_scan = &unit.scanner;
    if (panel_scan.quiet()) return;
    if (panel_scan.last) |picture| {
        try out.print(
            "GLCDC: panel scanned, {d} pixel(s), {d} distinct colour(s), {d} fully transparent, content {X:0>8}\n",
            .{ picture.pixels, picture.colours, picture.blank, picture.hash },
        );
    }
    if (panel_scan.count(.no_palette) != 0) {
        try out.print(
            "GLCDC: REFUSED {d} scan(s) of a CLUT layer with an empty palette plane (fill the CLUT, or point CLUTINT.SEL at the plane you filled)\n",
            .{panel_scan.count(.no_palette)},
        );
    }
    if (panel_scan.count(.off_ram) != 0 or panel_scan.count(.too_big) != 0) {
        try out.print(
            "GLCDC: REFUSED {d} scan(s) whose framebuffer ran past the end of its RAM window, {d} larger than this will walk\n",
            .{ panel_scan.count(.off_ram), panel_scan.count(.too_big) },
        );
    }
    if (panel_scan.count(.output_off) != 0) {
        try out.print(
            "GLCDC: {d} scan(s) with a layer fetching and the output stage off: the panel was dark\n",
            .{panel_scan.count(.output_off)},
        );
    }
    if (panel_scan.count(.fault) != 0) {
        try out.print(
            "GLCDC: {d} scan(s) where the framebuffer would not read back\n",
            .{panel_scan.count(.fault)},
        );
    }
}

/// How the two graphics layers reached the panel. dev picks one layer and
/// hashes its framebuffer, so an overlay over a background image, which is
/// the whole reason the block has two layers, was never in its witness: a
/// layer the driver hid with AB1.DISPSEL was reported as the picture, and a
/// layer positioned at a corner was reported as though it covered the panel.
fn composited(unit: anytype, out: Writer) !void {
    for (&unit.blends, 1..) |*stage, layer| {
        if (stage.quiet()) continue;
        const rect = stage.rect();
        try out.print(
            "GLCDC: GR{d} {s}, {d}x{d} at ({d},{d}), {d} pixel(s) shown, {d} held back, {d} chroma-keyed\n",
            .{
                layer,
                @tagName(stage.display()),
                rect.width,
                rect.height,
                rect.left,
                rect.top,
                stage.shown,
                stage.hidden,
                stage.keyed,
            },
        );
    }
    const mixer = &unit.mixer;
    if (mixer.quiet()) return;
    try out.print(
        "GLCDC: panel composited {d} time(s), {d} pixel(s) with two layers over each other, {d} showing the background colour\n",
        .{ mixer.mixes, mixer.overlapped, mixer.bare },
    );
}

/// The output stage: what the composited pixel became on the panel bus.
/// dev models none of this window, so a run that dithered down to a 16-bit
/// panel and one that drove a full 24-bit bus left the same witness behind.
fn outputStage(unit: anytype, out: Writer) !void {
    const stage = &unit.output;
    if (stage.quiet()) return;
    try out.print(
        "GLCDC: output bus {s}, dither {s}, gamma {s}, {d} pixel(s) out\n",
        .{
            @tagName(stage.live.format()),
            @tagName(stage.live.dither()),
            if (stage.gamma_on) "on" else "off",
            stage.pixels,
        },
    );
    if (stage.narrowed != 0 or stage.dithered != 0 or stage.corrected != 0) {
        try out.print(
            "GLCDC: {d} pixel(s) narrowed to the bus, {d} dithered, {d} gamma-corrected, {d} clipped\n",
            .{ stage.narrowed, stage.dithered, stage.corrected, stage.clipped },
        );
    }
    if (stage.pending()) {
        try out.print(
            "GLCDC: output registers written but never committed (OUT_VLATCH.VEN unwritten), so the panel is still driven from the previous settings\n",
            .{},
        );
    }
}

/// The palettes themselves, once a driver has filled one. dev snoops none of
/// the four CLUT planes, so every entry written went into a register shadow
/// nobody ever read back.
fn palettes(unit: anytype, out: Writer) !void {
    for (&unit.palettes, 1..) |*palette, layer| {
        if (palette.quiet()) continue;
        try out.print(
            "GLCDC: GR{d} CLUT plane 0 has {d} entry(s), plane 1 has {d}, CLUTINT.SEL reads plane {d}\n",
            .{ layer, palette.filled[0], palette.filled[1], palette.selected },
        );
    }
}

/// What the drawing engine actually put in the framebuffer. The loud case is
/// a declined render: the configuration was one this model will not invent
/// pixels for, so the app goes visibly blank here instead of passing on
/// pixels the bench would not have produced.
pub fn raster(board: *Board, out: Writer) !void {
    const unit = &board.raster;
    if (unit.quiet()) return;
    try out.print(
        "DRW: {d} box(es) rasterized, last {d}x{d}, {d} pixel(s)\n",
        .{ unit.renders, unit.last_width, unit.last_height, unit.pixels },
    );
    if (unit.limited != 0) {
        try out.print(
            "DRW: {d} render(s) shaped by the spatial limiters, {d} pixel(s) clipped out, {d} on a boundary this model paints hard\n",
            .{ unit.limited, unit.clipped, unit.hard_edges },
        );
    }
    try texture(unit, out);
    try caches(unit, out);
    if (unit.dlists != 0) {
        try out.print(
            "DRW: {d} display list(s), {d} stopped on an unmodelled entry\n",
            .{ unit.dlists, unit.dlist_stops },
        );
    }
    if (unit.declined != 0) {
        try out.print(
            "DRW: DECLINED {d} render(s), last because of {s} (unmodelled: nothing drawn)\n",
            .{ unit.declined, @tagName(unit.last_decline.?) },
        );
    }
    if (unit.faults != 0) {
        try out.print("DRW: {d} pixel access(es) went nowhere mapped\n", .{unit.faults});
    }
    if (unit.dropped_unpowered == 0 and unit.dark_reads == 0) return;
    try out.print(
        "DRW: DROPPED {d} write(s) and {d} read(s) with the graphics domain gated off (clear PDCTRGD.PDDE first)\n",
        .{ unit.dropped_unpowered, unit.dark_reads },
    );
}

/// The framebuffer cache, which dev declines rather than models: the HAL
/// enables it ahead of every stroked line and every triangle, so on dev
/// every one of those came back to a blank framebuffer and passed. Here the
/// render happens and the pixels sit in the cache until a CFLUSHFX, which
/// is worth saying out loud when a run ends with some still held.
fn caches(unit: anytype, out: Writer) !void {
    const fb = &unit.pixel_cache;
    if (fb.quiet()) return;
    try out.print(
        "DRW: framebuffer cache held {d} pixel write(s), wrote back {d} over {d} flush(es), {d} evicted to make room, {d} destination read(s) served from it\n",
        .{ fb.held, fb.written_back, fb.flushes, fb.evicted, fb.forwarded },
    );
    if (fb.dirty()) {
        try out.print(
            "DRW: {d} pixel(s) are STILL IN THE CACHE and not in memory (no CFLUSHFX since they were painted)\n",
            .{fb.used},
        );
    }
    if (fb.disabled_dirty != 0) {
        try out.print(
            "DRW: the framebuffer cache was switched off {d} time(s) with pixels still held (silicon leaves that undefined; written back here)\n",
            .{fb.disabled_dirty},
        );
    }
    if (fb.faults != 0) {
        try out.print("DRW: {d} cache write-back(s) went nowhere mapped\n", .{fb.faults});
    }
}

/// The texture source behind a blit, which dev models not at all: it
/// accepts the texture registers and discards them, then declines every
/// render with a source enabled, so every image, glyph and icon came back
/// to a blank framebuffer and the app passed.
fn texture(unit: *const @TypeOf(@as(Board, undefined).raster), out: Writer) !void {
    const source = &unit.texture;
    if (source.quiet()) return;
    try out.print(
        "DRW: {d} texel(s) sampled, {d} colour-keyed out, {d} coordinate(s) folded back into the texture\n",
        .{ source.texels, source.keyed, source.wrapped },
    );
    if (source.off_ram == 0 and source.faults == 0) return;
    try out.print(
        "DRW: REFUSED {d} texel read(s) aimed outside the RAM the engine reaches, {d} that went nowhere mapped\n",
        .{ source.off_ram, source.faults },
    );
}

/// PDCTRGD itself, once the firmware has been near it. A write dropped by
/// the PRC1 lock is the silent failure: no fault, no flag, domain still dark.
pub fn domain(board: *Board, out: Writer) !void {
    const unit = &board.domains.graphics;
    if (unit.quiet()) return;
    try out.print(
        "PWR-GRAPHICS: domain {s}, {d} power-on(s), {d} power-off(s)\n",
        .{ if (unit.powered()) "powered" else "GATED", unit.power_ons, unit.power_offs },
    );
    if (unit.dropped_locked == 0) return;
    try out.print(
        "PWR-GRAPHICS: DROPPED {d} write(s) with PRCR.PRC1 locked (unlock with 0xA502)\n",
        .{unit.dropped_locked},
    );
}
