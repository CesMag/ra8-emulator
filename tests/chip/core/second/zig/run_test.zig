//! Tests for src/chip/core/second_zig_run.zig: CPU1's turns under --cpu zig
//! (RA8EMU-234).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const second_core = ra8.chip.core.second.core;
const Driver = second_core.zig.run.Driver;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const Units = second_core.zig.Units;
const memmap = ra8.chip.core.memmap;
const Board = ra8.board.board.Board;
const icu = ra8.chip.periph.icu;
const dtc = ra8.chip.periph.dtc;
const xfer = ra8.chip.periph.dtc.xfer;

const vectors: u32 = memmap.sram_base + 0x1000;
const code: u32 = vectors + 0x200;
const stack: u32 = vectors + 0x800;

/// A driver whose CPU1 runs `program` from reset, built the way `open`
/// builds it but from words in its own store instead of an ELF on disk.
fn bring(driver: *Driver, board: *Board, program: []const u16) !void {
    driver.second = .{ .state = .{ .vector_base = vectors } };
    driver.wiring = null;
    driver.cycle_remainder = 0;
    driver.store = try Store.init(null);
    errdefer driver.close();
    const memory: Guest = .{ .store = &driver.store.? };
    try memory.writeWord(vectors, stack);
    try memory.writeWord(vectors + 4, code | 1);
    for (program, 0..) |half, i| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, half, .little);
        try memory.write(code + @as(u32, @intCast(2 * i)), &bytes);
    }
    try driver.core.openOn(memory, Units.of(&driver.second), &board.bus);
    driver.handTo(ra8.board.wiring.cpu1(board));
}

test "a round runs CPU1's share on its Zig core and counts it by core rate" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    // B . : a core that runs every instruction it is given.
    try bring(&driver, &board, &.{0xE7FE});
    defer driver.close();

    // No divider word on the board: CPU1 runs as many as CPU0 did.
    driver.round(100);
    driver.round(100);
    try std.testing.expectEqual(@as(usize, 2), driver.second.state.turns);
    try std.testing.expectEqual(@as(usize, 200), driver.second.state.ran);
    try std.testing.expectEqual(code, driver.second.state.pc);
    try std.testing.expectEqual(@as(?ra8.chip.core.fault.Fault, null), driver.second.state.fault);
}

test "a CPU1 that stops is reported where it stopped and takes no more turns" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    // MOVS r0, #1, then UDF with no fault handlers in the table: the
    // UsageFault escalates and the core cannot carry on.
    try bring(&driver, &board, &.{ 0x2001, 0xDE00 });
    defer driver.close();

    driver.round(50);
    const fault = driver.second.state.fault orelse return error.NoFault;
    try std.testing.expectEqual(driver.second.state.pc, fault.pc);
    try std.testing.expect(fault.detail.len > 0);
    const ran = driver.second.state.ran;
    try std.testing.expect(ran < 50);
    driver.round(50);
    try std.testing.expectEqual(@as(usize, 1), driver.second.state.turns);
    try std.testing.expectEqual(ran, driver.second.state.ran);
}

test "opening CPU1 hands its store to the board and closing takes it back" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    try bring(&driver, &board, &.{0xE7FE});
    const handed = board.cpu1 orelse return error.NotHanded;
    try std.testing.expect(handed.store == &driver.store.?);
    driver.close();
    try std.testing.expect(board.cpu1 == null);
}

/// The event INTSELR hands to CPU1, and the line CPU1's ICU links it to.
const routed: u16 = 7;
const line: usize = 3;

/// INTSELR word 0 holds events 0 to 31, one bit each (RA8EMU-150).
fn routeToCpu1(board: *Board) void {
    board.events.select.write(icu.intsel.wordAddress(0), 4, @as(u32, 1) << routed);
}

test "an event INTSELR gives CPU1 pends CPU1's NVIC line and not CPU0's" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var store0 = try Store.init(null);
    defer store0.deinit();
    const cpu0: Guest = .{ .store = &store0 };
    var driver: Driver = undefined;
    try bring(&driver, &board, &.{0xE7FE});
    defer driver.close();

    routeToCpu1(&board);
    board.events.cpu1[line] = routed;
    try board.raise(cpu0, routed);
    try std.testing.expectEqual(@as(u32, 1) << line, try driver.guest().readWord(memmap.nvic.ispr));
    try std.testing.expectEqual(@as(u32, 0), try cpu0.readWord(memmap.nvic.ispr));
}

test "a CPU0-routed peripheral event pends CPU0 and not CPU1" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var store0 = try Store.init(null);
    defer store0.deinit();
    const cpu0: Guest = .{ .store = &store0 };
    var driver: Driver = undefined;
    try bring(&driver, &board, &.{0xE7FE});
    defer driver.close();

    board.events.links[line] = routed;
    try board.raise(cpu0, routed);
    try std.testing.expectEqual(@as(u32, 1) << line, try cpu0.readWord(memmap.nvic.ispr));
    try std.testing.expectEqual(@as(u32, 0), try driver.guest().readWord(memmap.nvic.ispr));
}

test "a DTCE slot on CPU1's table is served by DTC1" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var store0 = try Store.init(null);
    defer store0.deinit();
    const cpu0: Guest = .{ .store = &store0 };
    var driver: Driver = undefined;
    try bring(&driver, &board, &.{0xE7FE});
    defer driver.close();

    // One byte copy, interrupt on the last transfer, in CPU1's store.
    const memory = driver.guest();
    const table: u32 = memmap.sram_base + 0x4000;
    const info: u32 = table + 0x100;
    const source: u32 = table + 0x140;
    const dest: u32 = table + 0x180;
    try memory.writeWord(dtc.entryAddress(table, line), info);
    try memory.writeWord(info + xfer.off.mr, (@as(u32, 0b0000_1000) << 24) | (@as(u32, 0b0000_1000) << 16));
    try memory.writeWord(info + xfer.off.sar, source);
    try memory.writeWord(info + xfer.off.dar, dest);
    try memory.writeWord(info + xfer.off.counts, @as(u32, 1) << 16);
    try memory.write(source, &.{0x5A});
    board.transfers1.table = .cpu1;
    board.transfers1.write(dtc.win_base + dtc.off.dtcvbr, 4, table);
    board.transfers1.write(dtc.win_base + dtc.off.dtcst, 1, dtc.field.start);

    routeToCpu1(&board);
    board.events.cpu1[line] = routed | icu.field.dtce;
    try board.raise(cpu0, routed);
    var copied: [1]u8 = undefined;
    try memory.read(dest, &copied);
    try std.testing.expectEqual(@as(u8, 0x5A), copied[0]);
    try std.testing.expectEqual(@as(u32, 1), board.transfers1.activations);
    try std.testing.expectEqual(@as(u32, 0), board.transfers.activations);
}

const pingpong_bytes = @embedFile("../../../../fixtures/trustzone/cpu1_pingpong_ipc.elf");
const pingpong_cpu1_bytes = @embedFile("../../../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");

test "cpu1_pingpong_ipc reaches its Non-secure target without a forced HardFault" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cpu1.elf", .data = pingpong_cpu1_bytes });
    const cpu1_path = try tmp.dir.realPathFileAlloc(std.testing.io, "cpu1.elf", std.testing.allocator);
    defer std.testing.allocator.free(cpu1_path);

    const image = try ra8.board.image.elf.Image.init(pingpong_bytes);
    var store = try Store.init(null);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try ra8.board.wiring.attachBlocks(&board, memory);
    try ra8.board.wiring.primeWindows(&board, memory, ra8.board.wiring.cpu0Windows(&board));
    const loaded = try ra8.board.image.load.read(image);
    _ = try ra8.chip.core.cpu.memory.load.image(memory, loaded.image());

    var driver: Driver = undefined;
    const cpu1_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, cpu1_path, std.testing.allocator, .limited(ra8.chip.core.second.core.limits.image_bytes));
    defer std.testing.allocator.free(cpu1_bytes);
    const cpu1 = try ra8.board.image.load.read(try ra8.board.image.elf.Image.init(cpu1_bytes));
    try driver.open(ra8.board.wiring.cpu1(&board), cpu1.image(), memory);
    defer driver.close();
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 50_000 };
    var clock: cli_app.zig.run.Clock = .{ .io = std.testing.io, .memory = memory, .board = &board, .timebase = &timebase, .cpu1 = &driver };
    var final: ra8.chip.core.cpu.boot.Regs = .{};
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try ra8.chip.core.cpu.boot.start(&discard.writer, .zig, memory, &board.bus, vector_base, 100_000, &timebase.ticks, .{
        .boundary = clock.boundary(),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
        .final = &final,
    });

    try std.testing.expect(final.pc >= 0x1208_0000 and final.pc < 0x1209_0000);
    try std.testing.expectEqual(@as(?ra8.chip.core.fault.Fault, null), driver.second.state.fault);
    const words: ra8.chip.periph.fault.status.Words = .{
        .cfsr = try memory.readWord(memmap.scb.cfsr),
        .hfsr = try memory.readWord(memmap.scb.hfsr),
        .sfsr = try memory.readWord(ra8.chip.periph.fault.status.secure.sfsr),
    };
    var fault_line: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&fault_line);
    try ra8.chip.periph.fault.status.line(&stream, words);
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "a divided CPU1 charges cycles for the CPU0 boundary duration" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    try bring(&driver, &board, &.{0xE7FE});
    defer driver.close();

    var dividers: u16 = 0x2020;
    driver.second.state.dividers = &dividers;
    driver.roundAt(1000, ra8.chip.periph.clocks.timebase.default_hz);
    try std.testing.expectEqual(@as(usize, 250), driver.second.state.ran);
    try std.testing.expectEqual(@as(u64, 250), driver.second.state.timebase.elapsed);
}

test "CPU1 preserves fractional cycles across a default-rate round" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    try bring(&driver, &board, &.{0xE7FE});
    defer driver.close();

    driver.roundAt(1, 8_000_000);
    driver.round(1);
    driver.roundAt(124, 8_000_000);
    try std.testing.expectEqual(@as(u64, 2), driver.second.state.timebase.elapsed);
}
