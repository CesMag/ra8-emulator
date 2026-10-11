//! Tests for src/chip/core/second_core.zig: a SYSRESETREQ from CPU1 (RA8EMU-59),
//! and seeding CPU1 with no engine open (RA8EMU-571).
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.core.second.core;
const memmap = ra8.chip.core.memmap;
const Board = ra8.board.board.Board;
const scb = ra8.chip.periph.scb;
const cpu_ctrl = ra8.chip.periph.cpu_ctrl;
const elf = ra8.board.image.elf;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

/// CPU1's own store beside CPU0's, sharing its SRAM, as the Zig run
/// builds them. Closed with `part`.
const Pair = struct {
    cpu0: Store,
    cpu1: Store,

    fn open(self: *Pair) !void {
        self.cpu0 = try Store.init(null);
        errdefer self.cpu0.deinit();
        self.cpu1 = try Store.init(&self.cpu0);
    }

    fn part(self: *Pair) void {
        self.cpu1.deinit();
        self.cpu0.deinit();
    }

    fn first(self: *Pair) Guest {
        return .{ .store = &self.cpu0 };
    }

    fn second(self: *Pair) Guest {
        return .{ .store = &self.cpu1 };
    }
};

test "a reset CPU1 asks for latches SWRF and reboots the part, as CPU0's does" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var cpu1: mod.Second = .{};
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.chip.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.control = scb.Scb.init();
    try cpu1.control.prime(pair.second());
    cpu1.takeResetRequest(pair.second());
    try std.testing.expect(!pending.requested);

    cpu1.state.wiring = ra8.board.wiring.cpu1(&board);
    const keyed: u32 = scb.key.write << scb.key.shift;
    try pair.second().writeWord(memmap.scb.aircr, keyed | scb.field.sysresetreq);
    cpu1.takeResetRequest(pair.second());
    try std.testing.expect(pending.requested);
    try std.testing.expect(board.causes.rstsr1 & ra8.chip.periph.reset.cause.swrf != 0);
    try std.testing.expectEqual(@as(u32, 1), board.causes.requests);
}

test "a reset the board performs holds CPU1 until it is released" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var cpu1: mod.Second = .{};
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.chip.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.state.wiring = ra8.board.wiring.cpu1(&board);
    try std.testing.expect(!cpu1.state.heldInReset(pair.second()));

    pending.performed = 1;
    try std.testing.expect(cpu1.state.heldInReset(pair.second()));
    try std.testing.expect(cpu1.state.heldInReset(pair.second()));
}

test "a fresh release after a reset brings CPU1 up out of CPU1INITVTOR" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var cpu1: mod.Second = .{};
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.chip.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.state.wiring = ra8.board.wiring.cpu1(&board);
    const table: u32 = memmap.sram_base + 0x400;

    board.requestReset(.software);
    pending.performed = 1;
    try std.testing.expect(cpu1.state.heldInReset(pair.second()));
    const page = &board.second_core;
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.initvtor, 4, table);
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.actcsr, 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    try std.testing.expect(!cpu1.state.heldInReset(pair.second()));
    try std.testing.expectEqual(@as(u32, 1), cpu1.state.restarts);
    try std.testing.expectEqual(table, cpu1.state.vector_base);
    // The Zig core takes the reset vector on its next turn (Driver.round).
    try std.testing.expect(cpu1.state.unvectored);
    try std.testing.expectEqual(table, try pair.second().readWord(memmap.scb.vtor));
}

test "a reset clears the release, so CPU1 stays held until CPU0 asks again" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const page = &board.second_core;
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.actcsr, 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    board.requestReset(.software);
    try std.testing.expect(!page.running());
}

const seed_page: usize = 0x1000;

/// One executable PT_LOAD segment at MRAM holding a vector pair whose
/// reset vector points back inside it, so vectorBase accepts it.
fn vectorImage() [seed_page * 2]u8 {
    var file: [seed_page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    head.* = .{
        .magic = .{ 0x7f, 'E', 'L', 'F' },
        .class = 1,
        .data = 1,
        .version = 1,
        .osabi = 0,
        .abiversion = 0,
        .pad = @splat(0),
        .e_type = 2,
        .e_machine = elf.em_arm,
        .e_version = 1,
        .e_entry = memmap.mram_base + 0x5,
        .e_phoff = @sizeOf(elf.Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Header),
        .e_phentsize = @sizeOf(elf.ProgramHeader),
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const header: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    header.* = .{ .p_type = elf.pt_load, .p_offset = seed_page, .p_vaddr = memmap.mram_base, .p_paddr = memmap.mram_base, .p_filesz = 8, .p_memsz = 8, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[seed_page..][0..4], memmap.sram_base + 0x8000, .little);
    std.mem.writeInt(u32, file[seed_page + 4 ..][0..4], memmap.mram_base + 0x5, .little);
    return file;
}

test "CPU1's image and VTOR are seeded into a store with no engine open" {
    var file = vectorImage();
    const image = try elf.Image.init(&file);
    var store = try Store.init(null);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };
    const loaded = try ra8.board.image.load.read(image);
    const seeded = try mod.seedImage(memory, loaded.image());
    try std.testing.expectEqual(@as(u32, 8), seeded.written);
    try std.testing.expectEqual(memmap.mram_base, seeded.vector_base);
    try std.testing.expectEqual(memmap.mram_base, try memory.readWord(memmap.scb.vtor));
    try std.testing.expectEqual(memmap.sram_base + 0x8000, try memory.readWord(memmap.mram_base));
    try std.testing.expectEqual(memmap.mram_base + 0x5, try memory.readWord(memmap.mram_base + 4));
}

test {
    _ = @import("second/state_test.zig");
}
