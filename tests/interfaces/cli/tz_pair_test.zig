//! RA8EMU-293's done condition: a TrustZone Secure image and its Non-secure
//! image (tests/fixtures/trustzone) run as one on the Zig core. The Secure
//! boot hands off with BLXNS, and the Non-secure side calls the three NSC CGC
//! veneers (SG, VSCCLRM/CLRM, FPCXT_NS save, BXNS back) and gets k_ra8_ok
//! from each.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("store_board.zig");

const elf = ra8.board.image.elf;
const zig_run = cli_app.zig.run;
const cpu_boot = ra8.chip.core.cpu.boot;
const loader = ra8.chip.core.cpu.memory.load;

const secure_bytes = @embedFile("../../fixtures/trustzone/tz_nsc_cgc_usb.elf");
const ns_bytes = @embedFile("../../fixtures/trustzone/tz_nsc_cgc_usb_ns.elf");
const budget: u64 = 3_000_000;

/// `.ns_bss` reporting globals in the Non-secure image (see the fixture README).
const init_step: u32 = 0x3210_DE0C;
const match: u32 = 0x3210_DE10;
const mismatch: u32 = 0x3210_DE14;
const clock_hz: u32 = 0x3210_DE18;

test "the Non-secure image calls every NSC veneer and gets back" {
    const secure = try elf.Image.init(secure_bytes);
    const ns = try elf.Image.init(ns_bytes);
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    // As cpu0_store.Cpu0: the Secure image after the board, then the `--ns` half.
    const secure_loaded = try ra8.board.image.load.read(secure);
    _ = try loader.image(core, secure_loaded.image());
    const ns_loaded = try ra8.board.image.load.read(ns);
    _ = try loader.image(core, ns_loaded.image());
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    var ran: u64 = 0;
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const vector_base = secure.vectorBase() orelse return error.MissingVectorTable;
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, vector_base, budget, &ran, .{
        .boundary = clock.boundary(),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
    });
    try std.testing.expectEqual(@as(u32, 4), try core.readWord(init_step));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(mismatch));
    try std.testing.expect(try core.readWord(match) > 0);
    try std.testing.expectEqual(@as(u32, 1_000_000_000), try core.readWord(clock_hz));
}
