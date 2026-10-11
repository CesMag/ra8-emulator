//! Covers src/interfaces/cli/zig/run.zig: the board's side of a Zig-core
//! boundary.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const memmap = ra8.chip.core.memmap;
const zig_run = cli_app.zig.run;
const profile = ra8.session.functions.profile;
const profile_report = cli_app.report.profile;
const cpu_boot = ra8.chip.core.cpu.boot;
const symbols = ra8.session.symbols;
const Builder = @import("../../../session/symbol_image.zig").Builder;
const store_board = @import("../store_board.zig");
const Store = store_board.Store;
const Guest = store_board.Guest;
const attach = store_board.attach;

test "a boundary is the chunk until SysTick is armed, then its period" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
    try core.writeWord(memmap.syst.rvr, 999);
    try core.writeWord(memmap.syst.csr, 0x7);
    try std.testing.expectEqual(@as(u32, 1000), clock.width());
    try core.writeWord(memmap.syst.rvr, 99_999);
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
}

test "closing a boundary charges the clocks and wraps SysTick into ICSR" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    try clock.close(7);
    try std.testing.expectEqual(@as(u64, 7), timebase.elapsed);
    try core.writeWord(memmap.syst.rvr, 9);
    try core.writeWord(memmap.syst.cvr, 0);
    try core.writeWord(memmap.syst.csr, 0x7);
    try clock.close(10);
    try std.testing.expectEqual(@as(u64, 17), timebase.elapsed);
    try std.testing.expect(timebase.ticks > 0);
}

test "closing a boundary charges cycles at the image core clock" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    board.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.moco);
    board.tree.selects = 1;
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 50_000 };
    var timed: ra8.chip.core.deadline.Deadline = .{ .periods = 1000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .timed = &timed };
    try core.writeWord(memmap.syst.rvr, 7999);
    try core.writeWord(memmap.syst.csr, 0x7);
    try std.testing.expectEqual(@as(u32, 50_000), clock.width());

    board.time.base.setRate(ra8.chip.periph.clocks.timebase.default_hz);
    clock.resume_boundary = true;
    clock.boundary_hz = null;
    try std.testing.expectEqual(@as(u32, 8000), clock.width());
    try std.testing.expectEqual(ra8.chip.periph.clocks.timebase.default_hz, board.time.base.hz);
    clock.resume_boundary = false;
    clock.boundary_hz = null;
    _ = clock.width();
    try std.testing.expectEqual(@as(u64, 8_000_000), board.time.base.hz);
    const gptp = ra8.chip.periph.gptp;
    const gptp_timer = ra8.chip.periph.gptp.timer;
    const unit = gptp.win_base + gptp.unitOffset(0);
    board.ptp.write(unit + gptp.unit_off.ptptivc, 4, 4 << gptp_timer.scale.subns_shift);
    board.ptp.write(gptp.win_base + gptp.off.ptptmec, 4, 1);
    try clock.close(1000);
    try std.testing.expectEqual(@as(u64, 8), timebase.elapsed);
    try std.testing.expectEqual(@as(u64, 8), board.time.base.retired);
    try std.testing.expectEqual(@as(u32, 1000), board.ptp.read(unit + gptp.unit_off.ptpgptptml, 4));
    try clock.close(4000);
    try std.testing.expectEqual(@as(u64, 40), timebase.elapsed);
    try std.testing.expectEqual(@as(u64, 40), board.time.base.retired);
    try std.testing.expect(!clock.done());
    try clock.close(999_995_000);
    try std.testing.expectEqual(@as(u64, 8_000_000), timebase.elapsed);
    try std.testing.expectEqual(@as(u64, 1000), timebase.ticks);
    try std.testing.expect(clock.done());
}

test "--run-for ends after its duration of a reset-clock image's own time (RA8EMU-762)" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    board.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.moco);
    board.tree.selects = 1;
    const options = try cli_app.cli.parse(&[_][]const u8{ "emu", "a.elf", "--run-for", "1s" });
    var timed = zig_run.stop_sym.deadline(options.ms) orelse return error.TestExpectedDeadline;
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 1_000_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .timed = &timed };
    try core.writeWord(memmap.syst.rvr, 7999);
    try core.writeWord(memmap.syst.csr, 0x7);
    var closes: usize = 0;
    while (!clock.done()) : (closes += 1) {
        if (closes > 4000) return error.TestDeadlineNeverMet;
        try clock.close(clock.width());
    }
    try std.testing.expectEqual(@as(u64, 8_000_000), board.time.base.hz);
    try std.testing.expectEqual(@as(u64, 1000), timebase.ticks);
    const now = board.time.base.now();
    try std.testing.expect(now >= std.time.ns_per_s and now < std.time.ns_per_s + std.time.ns_per_ms);
}

test "a SysTick rearm discards the current boundary rate" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    board.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.moco);
    board.tree.selects = 1;
    var timebase: ra8.chip.periph.clocks.Clocks = .{};
    var timed: ra8.chip.core.deadline.Deadline = .{ .periods = 1 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .timed = &timed };
    try core.writeWord(memmap.syst.rvr, 7999);
    try core.writeWord(memmap.syst.csr, 0x7);
    _ = clock.width();
    try std.testing.expectEqual(@as(?u64, 8_000_000), clock.boundary_hz);

    const boundary = clock.boundary();
    boundary.abortFn.?(boundary.context);
    try std.testing.expectEqual(@as(?u64, null), clock.boundary_hz);
    board.time.base.setRate(ra8.chip.periph.clocks.timebase.default_hz);
    _ = clock.width();
    try std.testing.expectEqual(@as(u64, 8_000_000), board.time.base.hz);
}

fn profileInstruction(context: *anyopaque, address: u32) void {
    const table: *profile.Table = @ptrCast(@alignCast(context));
    table.instruction(address);
}

test "a Zig core run profiles retired function instructions and writes folded output" {
    const base = memmap.sram_base;
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    try core.writeWord(base, memmap.sram_end);
    try core.writeWord(base + 4, base + 9);
    try core.writeWord(base + 8, 0xBF00_BF00);
    try core.writeWord(base + 12, 0xBF00_BF00);

    var image_bytes: [512]u8 = undefined;
    const encoded = Builder.build(&image_bytes, &.{"profiled_function"}, &.{base + 9});
    const symbol: *align(1) symbols.Symbol = std.mem.bytesAsValue(symbols.Symbol, encoded[Builder.sym_off..][0..@sizeOf(symbols.Symbol)]);
    symbol.st_info = symbols.symbol_type.func;
    symbol.st_size = 8;
    const image = try ra8.board.image.elf.Image.init(encoded);
    var table: profile.Table = .{ .image = image };
    table.prepare();

    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var ran: u64 = 0;
    var output: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const listener: ra8.chip.core.cpu.cpu.RetireListener = .{ .context = &table, .instructionFn = profileInstruction };
    const status = try cpu_boot.start(&stream, .zig, core, &board.bus, base, 3, &ran, .{ .retire_listener = listener });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 3), ran);
    var rows: [profile.limits.functions]profile.Site = undefined;
    const ranked = table.ranked(&rows);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqual(base + 8, ranked[0].address);
    try std.testing.expectEqual(@as(u64, 3), ranked[0].instructions);
    try std.testing.expectEqual(@as(u64, 3), ranked[0].cycles);

    const summary_path = ".ra8-profile-zig-run-test.out";
    const folded_path = ".ra8-profile-zig-run-test.folded";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, folded_path) catch {};
    var summary = try std.Io.Dir.cwd().createFile(std.testing.io, summary_path, .{ .truncate = true });
    defer summary.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = summary.writer(std.testing.io, &buffer);
    try profile_report.write(&writer.interface, std.testing.io, image, table, folded_path, null);
    try writer.interface.flush();
    const folded = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, folded_path, std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(folded);
    try std.testing.expectEqualStrings("profiled_function 3\n", folded);
}

test {
    _ = @import("../../../session/stack/profile_test.zig");
    _ = @import("main_test.zig");
    _ = @import("../idle_skip_equiv_test.zig");
    _ = @import("../sleep_wake_test.zig");
    _ = @import("../soak_done_test.zig");
    _ = @import("../soak_canary_test.zig");
    _ = @import("../threadx_stkof_test.zig");
    _ = @import("../tz_pair_test.zig");
}

test "a boundary is done once the --stop-sym counter reaches its floor (RA8EMU-603)" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var watch: ra8.chip.core.stop.Stop = .{ .address = 0x2200_0100, .reaches = 3 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .stop = &watch };
    try core.writeWord(0x2200_0100, 2);
    try std.testing.expect(!clock.done());
    try core.writeWord(0x2200_0100, 4);
    try std.testing.expect(clock.done());
    try std.testing.expect(watch.reached);
    const edge = clock.boundary();
    try std.testing.expect(edge.doneFn.?(edge.context));
}
