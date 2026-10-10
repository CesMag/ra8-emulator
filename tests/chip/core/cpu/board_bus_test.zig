//! Covers src/chip/core/cpu/board_bus.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const registry = ra8.chip.periph.registry;
const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
const Store = ra8.chip.core.cpu.memory.store.Store;

fn put(store: *Store, address: u32, value: u32) void {
    std.mem.writeInt(u32, store.span(address, 4).?[0..4], value, .little);
}

fn get(store: *Store, address: u32) u32 {
    return std.mem.readInt(u32, store.span(address, 4).?[0..4], .little);
}

/// One register block that remembers the last access it saw.
const Probe = struct {
    address: u32 = 0,
    width: u3 = 0,
    value: u32 = 0,

    fn read(context: *anyopaque, address: u32, width: u3) u32 {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.address = address;
        self.width = width;
        return 0xA1B2_C3D4;
    }

    fn write(context: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.address = address;
        self.width = width;
        self.value = value;
    }
};

const at = registry.base + 0x8_0000;

fn attach(periph: *registry.Bus, probe: *Probe) !void {
    try periph.add(.{
        .name = "probe",
        .base = at,
        .size = 0x100,
        .context = probe,
        .readFn = Probe.read,
        .writeFn = Probe.write,
    });
}

test "a halfword store in the peripheral window reaches the peripheral" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var probe: Probe = .{};
    try attach(&periph, &probe);
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph };
    try board.view().write(at + 4, &[_]u8{ 0x1A, 0x80 });
    try std.testing.expectEqual(@as(u32, at + 4), probe.address);
    try std.testing.expectEqual(@as(u3, 2), probe.width);
    try std.testing.expectEqual(@as(u32, 0x801A), probe.value);
}

test "a read in the Non-secure alias comes back from the same peripheral" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var probe: Probe = .{};
    try attach(&periph, &probe);
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph };
    try std.testing.expectEqual(@as(u32, 0xA1B2_C3D4), try board.view().readWord(at + registry.ns_offset));
    try std.testing.expectEqual(@as(u3, 4), probe.width);
    var byte: [1]u8 = undefined;
    try board.view().read(at, &byte);
    try std.testing.expectEqual(@as(u8, 0xD4), byte[0]);
}

test "memory outside the windows still goes to guest memory" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph };
    try board.view().write(memmap.sram_base, &[_]u8{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(u32, 0x0403_0201), get(&store, memmap.sram_base));
    try std.testing.expectEqual(@as(u32, 0), periph.counters.writes);
}

test "an access wider than one register is refused" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph };
    var wide: [8]u8 = undefined;
    try std.testing.expectError(error.Unmapped, board.view().read(at, &wide));
    try std.testing.expect(!BoardBus.inWindow(registry.base + registry.size - 2, 4));
    try std.testing.expect(BoardBus.inWindow(registry.ns_base, 4));
}

fn storeWord(board: *BoardBus, address: u32, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try board.view().write(address, &bytes);
}

test "SAU RBAR and RLAR bank through RNR on the Zig bus" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var partitions = ra8.chip.periph.sau.Sau.init();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .partitions = &partitions } };
    try storeWord(&board, memmap.sau.rnr, 1);
    try storeWord(&board, memmap.sau.rbar, 0x0200_0000);
    try storeWord(&board, memmap.sau.rlar, 0x0207_FFE1);
    try storeWord(&board, memmap.sau.rnr, 0);
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.sau.rbar));
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.sau.rlar));
    try storeWord(&board, memmap.sau.rnr, 1);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), try board.view().readWord(memmap.sau.rbar));
    try std.testing.expectEqual(@as(u32, 0x0207_FFE1), try board.view().readWord(memmap.sau.rlar));
    try std.testing.expectEqual(@as(u32, 2), partitions.banked);
}

test "a bus with no SAU leaves the window as plain RAM" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph };
    try storeWord(&board, memmap.sau.rbar, 0x0200_0000);
    try storeWord(&board, memmap.sau.rnr, 1);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), try board.view().readWord(memmap.sau.rbar));
}

test "MPU pairs bank through RNR on the Zig bus, aliases included" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var regions = ra8.chip.periph.mpu.Mpu.init();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .regions = &regions } };
    try storeWord(&board, memmap.mpu.rnr, 4);
    try storeWord(&board, memmap.mpu.rbar, 0x2200_0000);
    try storeWord(&board, memmap.mpu.rlar_a1, 0x2207_FFE1);
    try storeWord(&board, memmap.mpu.rnr, 0);
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.mpu.rbar));
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.mpu.rlar_a1));
    try storeWord(&board, memmap.mpu.rnr, 4);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), try board.view().readWord(memmap.mpu.rbar));
    try std.testing.expectEqual(@as(u32, 0x2207_FFE1), try board.view().readWord(memmap.mpu.rlar_a1));
}

test "CFSR and HFSR clear the bits a store writes ones to" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var clears = ra8.chip.core.cpu.board_bus.fault_clear.Clears.init();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .clears = &clears } };
    put(&store, memmap.scb.cfsr, 0x0001_0182);
    try storeWord(&board, memmap.scb.cfsr, 0x0000_0100);
    try std.testing.expectEqual(@as(u32, 0x0001_0082), try board.view().readWord(memmap.scb.cfsr));
    try board.view().write(memmap.scb.cfsr + 2, &[_]u8{ 0x01, 0x00 });
    try std.testing.expectEqual(@as(u32, 0x0000_0082), try board.view().readWord(memmap.scb.cfsr));
    put(&store, memmap.scb.hfsr, 0x4000_0002);
    try storeWord(&board, memmap.scb.hfsr, 0x4000_0000);
    try std.testing.expectEqual(@as(u32, 0x0000_0002), try board.view().readWord(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u32, 3), clears.stores);
}

test "a fault the core latches survives the CFSR, HFSR and SFSR write-one-to-clear" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var clears = ra8.chip.core.cpu.board_bus.fault_clear.Clears.init();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .clears = &clears } };
    const sfsr: u32 = 0xE000_EDE4;
    for ([_][2]u32{ .{ memmap.scb.cfsr, 0x0002_0000 }, .{ memmap.scb.hfsr, 0x4000_0000 }, .{ sfsr, 0x0000_0001 } }) |raise| {
        put(&store, raise[0], 0x0000_0002);
        try board.view().latch(raise[0], raise[1]);
        try std.testing.expectEqual(raise[1] | 0x0000_0002, try board.view().readWord(raise[0]));
    }
    try std.testing.expectEqual(@as(u32, 0), clears.stores);
}

test "word stores and loads of FPCCR, FPCAR and FPDSCR reach the core's FP state" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var fp: ra8.chip.core.cpu.fpu.state.State = .{};
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .fp = &fp } };
    const fp_at = ra8.chip.core.cpu.fpu.scb.address;
    try storeWord(&board, fp_at.fpccr, 0x0000_0001);
    try storeWord(&board, fp_at.fpcar, 0x2000_0104);
    try storeWord(&board, fp_at.fpdscr, 0x0040_0000);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), fp.context.readFpccr());
    try std.testing.expectEqual(@as(u32, 0x2000_0100), fp.context.fpcar);
    try std.testing.expectEqual(fp.context.fpdscr, try board.view().readWord(fp_at.fpdscr));
    try std.testing.expectEqual(@as(u32, 0x2000_0100), get(&store, fp_at.fpcar));
    fp.context.fpccr.lspact = 0;
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(fp_at.fpccr));
}

test "a word store to CPACR on a board run lands in the core's FP state" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var fp: ra8.chip.core.cpu.fpu.state.State = .{};
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .fp = &fp } };
    const cpacr = ra8.chip.core.cpu.fpu.scb.address.cpacr;
    try storeWord(&board, cpacr, ra8.chip.core.cpu.fpu.cpacr.full_access | 0x0000_000F);
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.cpacr.full_access, fp.cpacr);
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.cpacr.full_access, try board.view().readWord(cpacr));
    try std.testing.expectEqual(ra8.chip.core.cpu.fpu.cpacr.full_access, get(&store, cpacr));
}

test "faults reads the latched CFSR, HFSR and SFSR for the run report" {
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var clears = ra8.chip.core.cpu.board_bus.fault_clear.Clears.init();
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .clears = &clears } };
    try board.view().latch(memmap.scb.cfsr, 0x0002_0000);
    try board.view().latch(memmap.scb.hfsr, 0x4000_0000);
    try board.view().latch(0xE000_EDE4, 0x0000_0001);
    const words = board.faults();
    try std.testing.expectEqual(@as(u32, 0x0002_0000), words.cfsr);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), words.hfsr);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), words.sfsr);
}

test "a byte stored to STIM0 lands in the ITM and STIM0 reads FIFOREADY again" {
    const itm = ra8.chip.periph.itm;
    var store = try Store.init(null);
    defer store.deinit();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var port: itm.Itm = .{ .tcr = itm.tcr_bits.itmena, .ter = 1 };
    var board: BoardBus = .{ .memory = .{ .store = .{ .store = &store } }, .periph = &periph, .scs = .{ .itm = &port } };
    try board.view().write(itm.base, "h");
    try board.view().write(itm.base, "i");
    try std.testing.expectEqualStrings("hi", port.output());
    try std.testing.expectEqual(itm.fifo_ready, try board.view().readWord(itm.base));
}
