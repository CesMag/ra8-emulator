//! RA8EMU-243's done condition: a real ThreadX image (RA8FW-503's
//! threadx_stkof, tests/fixtures/threadx) runs one thread past its stack on
//! the Zig core. The port loads PSPLIM per thread, so the overflow raises
//! UsageFault with UFSR.STKOF, ThreadX's stack-error handler runs, and the
//! image reports it on the SCI console.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("store_board.zig");

const elf = ra8.board.image.elf;
const zig_run = cli_app.zig_run;
const cpu_boot = ra8.chip.core.cpu.boot;
const loader = ra8.chip.core.cpu.memory.load;

const image_bytes = @embedFile("../../fixtures/threadx/threadx_stkof.elf");
const budget: u64 = 5_000_000;

test "a ThreadX thread overflowing its stack is caught by the stack limit" {
    const image = try elf.Image.init(image_bytes);
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    // As cpu0_store.Cpu0.attachStore: the image goes in after the board, and
    // the loader maps its option-setting windows too.
    const loaded = try ra8.board.image.load.read(image);
    _ = try loader.image(core, loaded.image());
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    var ran: u64 = 0;
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, vector_base, budget, &ran, .{
        .boundary = clock.boundary(),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
    });
    try std.testing.expectEqual(@as(u32, 3), board.serial.line.lines);
    try std.testing.expectEqualStrings("stkof: PASS", board.serial.line.slice());
}
