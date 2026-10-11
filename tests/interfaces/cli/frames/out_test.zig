//! Tests for numbered P6 output in src/interfaces/cli/frames/out.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const frames_out = cli_app.report.frames.out;
const store_board = @import("../store_board.zig");
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_sys = ra8.chip.periph.glcdc.sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

test "a small panel writes exact P6 bytes and skips an identical scan" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.init(std.testing.allocator, std.testing.io, path, 1);
    defer sequence.deinit();
    const pixels = [_]u32{ 0xFF11_2233, 0x0044_5566 };
    try sequence.record(2, 1, &pixels, 0);
    try sequence.record(2, 1, &pixels, 16_666_667);
    try std.testing.expectEqual(@as(usize, 2), sequence.scanned);
    try std.testing.expectEqual(@as(usize, 1), sequence.written);

    const bytes = try sequence.directory.readFileAlloc(std.testing.io, "frame_00000.ppm", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n\x11\x22\x33\x44\x55\x66", bytes);
    try std.testing.expectError(error.FileNotFound, sequence.directory.openFile(std.testing.io, "frame_00001.ppm", .{}));
}

test "every Nth scan gets a sequential filename" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.init(std.testing.allocator, std.testing.io, path, 2);
    defer sequence.deinit();
    const first = [_]u32{0xFF00_0001};
    const second = [_]u32{0xFF00_0002};
    const third = [_]u32{0xFF00_0003};
    try sequence.record(1, 1, &first, 0);
    try sequence.record(1, 1, &second, 40);
    try sequence.record(1, 1, &third, 80);
    try std.testing.expectEqual(@as(usize, 2), sequence.written);
    try expectIndex(sequence, "frame_00000.ppm 0\nframe_00001.ppm 80\n");
    const bytes = try sequence.directory.readFileAlloc(std.testing.io, "frame_00001.ppm", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n1 1\n255\n\x00\x00\x03", bytes);
}

test "capture records the panel pixels from a completed GLCDC scan" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);

    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF11_2233);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.init(std.testing.allocator, std.testing.io, path, 1);
    defer sequence.deinit();
    var capture = (try frames_out.FrameCapture.init(std.testing.allocator, &board)).?;
    defer capture.deinit(&board);
    try std.testing.expect(board.display.scanOut() != null);
    try capture.finish(&board, &sequence);

    try std.testing.expectEqual(@as(u32, 1), board.display.system.frames);
    try std.testing.expectEqual(@as(usize, 1), sequence.written);
    const bytes = try sequence.directory.readFileAlloc(std.testing.io, "frame_00000.ppm", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n\x11\x22\x33\x11\x22\x33", bytes);
    try expectIndex(sequence, "frame_00000.ppm 0\n");
}

/// frames.txt names each written frame with the emulated time it was scanned.
fn expectIndex(sequence: frames_out.Sequence, expected: []const u8) !void {
    const bytes = try sequence.directory.readFileAlloc(std.testing.io, "frames.txt", std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "an armed run keeps one frame per period with its emulated time" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);
    const gif_path = try std.fs.path.join(std.testing.allocator, &.{ root, "movie.gif" });
    defer std.testing.allocator.free(gif_path);

    const armed = (try frames_out.Armed.armOutputs(std.testing.allocator, std.testing.io, &board, path, gif_path, 1)).?;
    defer armed.deinit();
    const period = ra8.chip.periph.glcdc.out.vsync.default_period_ns;
    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF11_2233);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);

    board.display.output.vsync.?.tick(period);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF44_5566);
    board.display.output.vsync.?.tick(2 * period);
    try std.testing.expect(frames_out.Armed.of(&board) == armed);

    var report = try frames_out.Run.init(std.testing.allocator, std.testing.io, &board, path, 1);
    try report.finish(&board);
    try std.testing.expectEqual(@as(usize, 2), armed.sequence.written);
    try std.testing.expectEqual(@as(usize, 2), armed.sequence.gif_writer.?.encoder.wrote);
    try expectIndex(armed.sequence, "frame_00000.ppm 16666667\nframe_00001.ppm 33333334\n");
    const bytes = try armed.sequence.directory.readFileAlloc(std.testing.io, "frame_00001.ppm", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n\x44\x55\x66\x44\x55\x66", bytes);
}

test "an attached e-ink refresh records its grey glass plane once per refresh" {
    const proto = ra8.components.eink.wire;
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.asks.attached_eink = &board.panel;
    board.panel.planes.resize(.{ .width = 128, .height = 128 });

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);
    const armed = (try frames_out.Armed.arm(std.testing.allocator, std.testing.io, &board, path, 1)).?;
    defer armed.deinit();

    eInkRefresh(&board.panel, proto, 0x2211);
    eInkRefresh(&board.panel, proto, 0x4433);
    try armed.finish();

    try std.testing.expectEqual(@as(usize, 2), armed.sequence.written);
    try expectIndex(armed.sequence, "frame_00000.ppm 0\nframe_00001.ppm 0\n");
    for ([_]struct { name: []const u8, rgb: [6]u8 }{
        .{ .name = "frame_00000.ppm", .rgb = .{ 0x11, 0x11, 0x11, 0x22, 0x22, 0x22 } },
        .{ .name = "frame_00001.ppm", .rgb = .{ 0x33, 0x33, 0x33, 0x44, 0x44, 0x44 } },
    }) |frame| {
        const bytes = try armed.sequence.directory.readFileAlloc(std.testing.io, frame.name, std.testing.allocator, .limited(128 * 128 * 3 + 32));
        defer std.testing.allocator.free(bytes);
        const header = "P6\n128 128\n255\n";
        try std.testing.expect(std.mem.startsWith(u8, bytes, header));
        try std.testing.expectEqualSlices(u8, &frame.rgb, bytes[header.len .. header.len + 6]);
        try std.testing.expectEqual(@as(u8, 0), bytes[header.len + 6]);
    }
}

test "with no attach, the board's own e-ink refreshes become the sequence" {
    const proto = ra8.components.eink.wire;
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.panel.planes.resize(.{ .width = 16, .height = 8 });

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "frames" });
    defer std.testing.allocator.free(path);
    const armed = (try frames_out.Armed.arm(std.testing.allocator, std.testing.io, &board, path, 1)).?;
    eInkRefresh(&board.panel, proto, 0x2211);
    eInkRefresh(&board.panel, proto, 0x4433);
    try armed.finish();
    try std.testing.expectEqual(@as(usize, 2), armed.sequence.written);
    try std.testing.expectEqual(@as(u32, 2), armed.board_eink_frames);
    try expectIndex(armed.sequence, "frame_00000.ppm 0\nframe_00001.ppm 0\n");
    armed.deinit();
    try std.testing.expect(board.panel.refresh_hook == null);
}

fn eInkRefresh(panel: *ra8.components.eink.Panel, proto: anytype, pixels: u16) void {
    panelWord(panel, proto.preamble.command);
    panelWord(panel, @backingInt(proto.Command.load_area));
    for ([_]u16{ 0x0030, 0, 0, 2, 1, pixels }) |value| {
        panelWord(panel, proto.preamble.write);
        panelWord(panel, value);
    }
    panelWord(panel, proto.preamble.command);
    panelWord(panel, @backingInt(proto.Command.display_area));
    for ([_]u16{ 0, 0, 2, 1, 2 }) |value| {
        panelWord(panel, proto.preamble.write);
        panelWord(panel, value);
    }
}

fn panelWord(panel: *ra8.components.eink.Panel, value: u16) void {
    _ = panel.exchange(@intCast(value >> 8));
    _ = panel.exchange(@intCast(value & 0xFF));
}

test "GIF output follows the sampled sequence when no PPM directory is requested" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "movie.gif" });
    defer std.testing.allocator.free(path);

    var sequence = try frames_out.Sequence.initOutputs(std.testing.allocator, std.testing.io, null, path, 1);
    defer sequence.deinit();
    const first = [_]u32{0xFF00_0000};
    const second = [_]u32{0xFFFF_FFFF};
    try sequence.record(1, 1, &first, 0);
    try sequence.record(1, 1, &second, 20_000_000);
    try sequence.finish();
    try std.testing.expectEqual(@as(usize, 2), sequence.written);

    var file = try temp.dir.openFile(std.testing.io, "movie.gif", .{});
    defer file.close(std.testing.io);
    var header: [6]u8 = undefined;
    var reader = file.reader(std.testing.io, &.{});
    try reader.interface.readSliceAll(&header);
    try std.testing.expectEqualSlices(u8, "GIF89a", &header);
}

test "an overlapping e-ink refresh burst produces one settled frame" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.panel.planes.resize(.{ .width = 2, .height = 1 });
    try std.testing.expect(board.panel.planes.ready());

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "settled" });
    defer std.testing.allocator.free(path);
    const options = try cli_app.cli.parse(&.{ "emu", "image.elf", "--frame-on-settle", path, "--settle-window-ms", "1" });
    const armed = (try frames_out.Armed.armForCli(std.testing.allocator, std.testing.io, &board, options.frames)).?;
    defer armed.deinit();

    board.panel.film.start();
    board.panel.film.start();
    for (0..6) |_| _ = board.panel.film.poll();
    try armed.pollSettle(25);
    try std.testing.expectEqual(@as(usize, 1), armed.sequence.written);
    try expectIndex(armed.sequence, "frame_00000.ppm 25\n");
}

test "a GLCDC burst settles once the picture holds for the window, and only once" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "settled" });
    defer std.testing.allocator.free(path);
    const options = try cli_app.cli.parse(&.{ "emu", "image.elf", "--frame-on-settle", path });
    const armed = (try frames_out.Armed.armForCli(std.testing.allocator, std.testing.io, &board, options.frames)).?;
    defer armed.deinit();
    const a = [_]u32{ 1, 2 };
    const b = [_]u32{ 3, 4 };
    try armed.observeFrame(2, 1, &a, 0);
    try armed.observeFrame(2, 1, &b, 10_000_000);
    try armed.observeFrame(2, 1, &b, 40_000_000);
    try std.testing.expectEqual(@as(usize, 0), armed.sequence.written);
    try armed.observeFrame(2, 1, &b, 60_000_000);
    try armed.observeFrame(2, 1, &b, 200_000_000);
    try std.testing.expectEqual(@as(usize, 1), armed.sequence.written);
    try expectIndex(armed.sequence, "frame_00000.ppm 60000000\n");
}

test "frame-on-settle can share a run with ordinary frames" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const settled = try std.fs.path.join(std.testing.allocator, &.{ root, "a" });
    defer std.testing.allocator.free(settled);
    const frames = try std.fs.path.join(std.testing.allocator, &.{ root, "b" });
    defer std.testing.allocator.free(frames);
    const options = try cli_app.cli.parse(&.{ "emu", "image.elf", "--frame-on-settle", settled, "--frames-out", frames });
    const armed = (try frames_out.Armed.armForCli(std.testing.allocator, std.testing.io, &board, options.frames)).?;
    defer armed.deinit();
    try std.testing.expect(!armed.settle_only);
    try std.testing.expect(armed.settle_sequence != null);
}
