//! Tests for src/chip/periph/mpu/mpu_ns.zig, and the Zig core's bus filing
//! Non-secure MPU programming into its own bank through it (RA8EMU-447).

const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const registry = ra8.chip.periph.registry;
const mpu_ns = ra8.chip.periph.mpu.ns;
const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
const store_memory = @import("../store_memory.zig");
const Banked = ra8.chip.core.banked.Banked;

const rbar_alias: u32 = memmap.mpu.rbar + mpu_ns.offset;
const rnr_alias: u32 = memmap.mpu.rnr + mpu_ns.offset;

test "the Non-secure view of an MPU register names its copy" {
    try std.testing.expectEqual(rbar_alias, mpu_ns.copyOf(memmap.mpu.rbar, false).?);
    try std.testing.expectEqual(rbar_alias, mpu_ns.copyOf(rbar_alias, true).?);
    try std.testing.expectEqual(@as(?u32, null), mpu_ns.copyOf(memmap.mpu.rbar, true));
}

test "Non-secure code on the alias and words outside the MPU name no copy" {
    try std.testing.expectEqual(@as(?u32, null), mpu_ns.copyOf(rbar_alias, false));
    try std.testing.expectEqual(@as(?u32, null), mpu_ns.copyOf(0xE000_ED8C, false));
    try std.testing.expectEqual(@as(?u32, null), mpu_ns.copyOf(0xE000_EDC8, false));
    try std.testing.expectEqual(@as(u32, 0xE002_EDC4), mpu_ns.copyOf(memmap.mpu.mair1, false).?);
}

test "normalOf takes a copy address back and nothing else" {
    try std.testing.expectEqual(memmap.mpu.rbar, mpu_ns.normalOf(rbar_alias).?);
    try std.testing.expectEqual(@as(?u32, null), mpu_ns.normalOf(memmap.mpu.rbar));
    try std.testing.expectEqual(@as(?u32, null), mpu_ns.normalOf(0x10));
}

fn storeWord(board: *BoardBus, address: u32, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try board.view().write(address, &bytes);
}

fn region(board: *BoardBus, rnr: u32, number: u32, rbar: u32, value: u32) !void {
    try storeWord(board, rnr, number);
    try storeWord(board, rbar, value);
}

test "Secure and Non-secure MPU programming stay apart on the Zig bus" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var secure_mpu = ra8.chip.periph.mpu.Mpu.init();
    var ns_mpu = ra8.chip.periph.mpu.Mpu.init();
    var state: Banked = .{};
    var board: BoardBus = .{
        .memory = .{ .store = .{ .store = memory.store } },
        .periph = &periph,
        .security = &state,
        .scs = .{ .regions = &secure_mpu, .regions_ns = &ns_mpu },
    };
    try region(&board, memmap.mpu.rnr, 4, memmap.mpu.rbar, 0x2200_0000);
    try region(&board, rnr_alias, 2, rbar_alias, 0x2210_0000);
    state.current = .non_secure;
    try region(&board, memmap.mpu.rnr, 3, memmap.mpu.rbar, 0x2220_0000);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), secure_mpu.table[4].rbar);
    try std.testing.expectEqual(@as(u32, 0), secure_mpu.table[2].rbar);
    try std.testing.expectEqual(@as(u32, 0), secure_mpu.table[3].rbar);
    try std.testing.expectEqual(@as(u32, 0x2210_0000), ns_mpu.table[2].rbar);
    try std.testing.expectEqual(@as(u32, 0x2220_0000), ns_mpu.table[3].rbar);
    try std.testing.expectEqual(@as(u32, 0), ns_mpu.table[4].rbar);
    try storeWord(&board, memmap.mpu.rnr, 2);
    try std.testing.expectEqual(@as(u32, 0x2210_0000), try board.view().readWord(memmap.mpu.rbar));
    state.current = .secure;
    try std.testing.expectEqual(@as(u32, 0x2200_0000), try board.view().readWord(memmap.mpu.rbar));
    try std.testing.expectEqual(@as(u32, 0x2210_0000), try board.view().readWord(rbar_alias));
}

test "with no Non-secure MPU wired the alias keeps its old path" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var secure_mpu = ra8.chip.periph.mpu.Mpu.init();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = memory.store } }, .periph = &periph, .scs = .{ .regions = &secure_mpu } };
    try region(&board, memmap.mpu.rnr, 4, memmap.mpu.rbar, 0x2200_0000);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), secure_mpu.table[4].rbar);
}

test "prime puts the region count in the Non-secure MPU_TYPE word" {
    const Fake = struct {
        address: u32 = 0,
        value: u32 = 0,
        pub fn writeWord(self: *@This(), address: u32, value: u32) !void {
            self.address = address;
            self.value = value;
        }
    };
    var fake: Fake = .{};
    try mpu_ns.prime(&fake, 0x800);
    try std.testing.expectEqual(memmap.mpu.type_ + mpu_ns.offset, fake.address);
    try std.testing.expectEqual(@as(u32, 0x800), fake.value);
}
