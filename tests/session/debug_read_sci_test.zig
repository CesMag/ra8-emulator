//! A debugger read over a SCI channel through the Zig core's board bus
//! (RA8EMU-949): 16 bytes from RDR show the queued byte, take nothing, and
//! the guest's own load takes it afterwards.
const std = @import("std");
const ra8 = @import("ra8");
const registry = ra8.chip.periph.registry;
const sci = ra8.chip.periph.sci;
const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
const Banked = ra8.chip.core.banked.Banked;
const debug_read = ra8.session.step_hook.debug_read;
const store_memory = @import("../chip/periph/store_memory.zig");

const channel: usize = 3;

test "a debugger read over RDR leaves the queued byte for the guest" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var unit = sci.Sci.init();
    try periph.add(unit.block());
    var secure_mpu = ra8.chip.periph.mpu.Mpu.init();
    var ns_mpu = ra8.chip.periph.mpu.Mpu.init();
    var state: Banked = .{};
    var board: BoardBus = .{
        .memory = .{ .store = .{ .store = memory.store } },
        .periph = &periph,
        .security = &state,
        .scs = .{ .regions = &secure_mpu, .regions_ns = &ns_mpu },
    };
    unit.write(sci.regAddress(channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
    unit.feed(channel, "!");
    const rdr = sci.regAddress(channel, sci.off_rdr);

    var shown: [16]u8 = undefined;
    try debug_read.read(board.view(), rdr, &shown);
    try std.testing.expectEqual(@as(u8, '!'), shown[0]);
    try debug_read.read(board.view(), rdr, &shown);
    try std.testing.expectEqual(@as(u8, '!'), shown[0]);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[channel].received);

    var taken: [4]u8 = undefined;
    try board.view().read(rdr, &taken);
    try std.testing.expectEqual(@as(u8, '!'), taken[0]);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[channel].received);
}
