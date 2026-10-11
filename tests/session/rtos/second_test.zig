//! Tests for CPU1's `--trace-rtos` (src/session/rtos/second.zig): a tracer
//! made for core 1 in front of CPU1's Zig core takes its stores to the
//! pointer, tagged cpu1 and stamped from that core's clock.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.chip.core.memmap;
const rtos_hook = ra8.session.step_hook.rtos.hook;

const pointer: u32 = memmap.sram_base + 0x1ABC;
const thread: u32 = memmap.sram_base + 0x10F0;
const code: u32 = memmap.sram_base + 0x40;
// str r1, [r0]   then   b .
const store_then_park = [_]u8{ 0x01, 0x60, 0xfe, 0xe7 };

const Board = ra8.board.board.Board;
const Driver = ra8.chip.core.second.core.zig.run.Driver;
const vectors: u32 = memmap.sram_base + 0x1000;
const zig_code: u32 = vectors + 0x200;

/// CPU1 on its Zig core, reset into STR r1, [r0] then B . from its own store.
fn bring(driver: *Driver, board: *Board) !void {
    driver.second = .{ .state = .{ .vector_base = vectors } };
    driver.wiring = null;
    driver.cycle_remainder = 0;
    driver.store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    errdefer driver.close();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &driver.store.? };
    try memory.writeWord(vectors, vectors + 0x800);
    try memory.writeWord(vectors + 4, zig_code | 1);
    try memory.write(zig_code, &store_then_park);
    try driver.core.openOn(memory, ra8.chip.core.second.core.zig.Units.of(&driver.second), &board.bus);
    driver.core.cpu.regs.set(0, pointer);
    driver.core.cpu.regs.set(1, thread);
}

test "a core-1 tracer in front of CPU1's Zig core records its switch as cpu1" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    try bring(&driver, &board);
    defer driver.close();
    var tracer: rtos_hook.Tracer = .{ .address = pointer, .core = 1 };
    rtos_hook.second.listenZig(&driver, &tracer);
    driver.round(3);
    const events = tracer.trace.list();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(u1, 1), events[0].core);
    try std.testing.expectEqual(thread, events[0].thread);
}
