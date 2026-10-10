//! RA8EMU-619's done condition: a host-assembled image that overwrites its
//! stack canary after two virtual minutes ends a soak at that minute. The
//! image is idler.zig's counting SysTick handler with a one-second period at
//! a 1 MHz core clock, and a reset handler that sleeps until the handler
//! has counted 120 wraps (the first lands a full second in), then stores
//! over the canary and sleeps. The soak sees it at the next boundary, which
//! ends that sleep at the 121st wrap, one second later (RA8EMU-657).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("store_board.zig");
const idler = @import("idler.zig");

const zig_run = cli_app.zig_run;
const cpu_boot = ra8.chip.core.cpu.boot;
const memmap = ra8.chip.core.memmap;
const soak = ra8.board.run.soak;

const hz: u64 = 1_000_000;
const ns_per_s: u64 = 1_000_000_000;
const reset_at = idler.base + 0x200;
const canary_at = memmap.sram_end - 0x100;
const fill: u32 = 0xEFEF_EFEF;
const wraps: u8 = 120;

fn load(core: anytype) !void {
    try idler.load(core);
    try core.writeWord(memmap.syst.rvr, @intCast(hz - 1));
    try core.writeWord(canary_at, fill);
    try core.writeWord(idler.base + 4, reset_at | 1);
    // ldr r2, =canary; wfi
    try core.writeWord(reset_at, 0xBF30_4A03);
    // ldr r1, =counter; ldr r1, [r1]
    try core.writeWord(reset_at + 4, 0x6809_4903);
    // cmp r1, #wraps; bne wfi
    try core.writeWord(reset_at + 8, 0xD1FA_2900 | @as(u32, wraps));
    // str r1, [r2]; b .
    try core.writeWord(reset_at + 12, 0xE7FE_6011);
    try core.writeWord(reset_at + 16, canary_at);
    try core.writeWord(reset_at + 20, idler.counter_at);
}

test "a soak ends at the virtual minute the firmware overwrites its canary" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    try load(core);
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    board.time.base.setRate(hz);
    board.run.soak.armed = true;
    try board.run.soak.watch.add(.{ .address = canary_at, .expected = fill, .kind = .stack_canary });
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .idle_skip = true };
    var ran: u64 = 0;
    var final: cpu_boot.Regs = .{};
    var output: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    _ = try cpu_boot.start(&stream, .zig, core, &board.bus, idler.base, 3600 * hz, &ran, .{ .boundary = clock.boundary(), .final = &final });
    clock.soakFaults();
    const event = board.run.soak.event orelse return error.NoEvent;
    try std.testing.expectEqual(soak.Kind.stack_canary, event.kind);
    try std.testing.expectEqual(@as(?u32, canary_at), event.word);
    try std.testing.expectEqual(@as(u32, wraps), try core.readWord(idler.counter_at));
    try std.testing.expect(event.at_ns > 120 * ns_per_s);
    try std.testing.expect(event.at_ns < 122 * ns_per_s);
    try std.testing.expectEqual(@as(u64, 2), event.at_ns / (60 * ns_per_s));
}
