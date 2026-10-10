//! Tests for src/chip/core/second_zig.zig: CPU1 on the Zig core (RA8EMU-234).
const std = @import("std");
const ra8 = @import("ra8");
const second_core = ra8.chip.core.second_core;
const SecondZig = second_core.zig.SecondZig;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const memmap = ra8.chip.core.memmap;
const Board = ra8.board.board.Board;

const vectors: u32 = memmap.sram_base + 0x1000;
const code: u32 = vectors + 0x200;
const stack: u32 = vectors + 0x800;
const usage_handler: u32 = vectors + 0x400;
const hard_handler: u32 = vectors + 0x440;
const usgfaultena: u32 = 1 << 18;

/// CPU1's own store beside CPU0's, sharing its SRAM, with CPU1's vector
/// table in it, the way the Zig run lays them out. Closed with `part`.
const Pair = struct {
    cpu0: Store,
    cpu1: Store,
    second: second_core.Second,

    fn open(self: *Pair) !void {
        self.cpu0 = try Store.init(null);
        errdefer self.cpu0.deinit();
        self.cpu1 = try Store.init(&self.cpu0);
        errdefer self.cpu1.deinit();
        self.second = .{ .state = .{ .vector_base = vectors } };
        const memory = self.guest();
        try memory.writeWord(vectors, stack);
        try memory.writeWord(vectors + 4, code | 1);
        try memory.writeWord(vectors + 3 * 4, hard_handler | 1);
        try memory.writeWord(vectors + 6 * 4, usage_handler | 1);
    }

    fn part(self: *Pair) void {
        self.cpu1.deinit();
        self.cpu0.deinit();
    }

    fn guest(self: *Pair) Guest {
        return .{ .store = &self.cpu1 };
    }

    /// CPU1's Zig core over its store, with CPU1's own units.
    fn bring(self: *Pair, core: *SecondZig, board: *Board) !void {
        try core.openOn(self.guest(), second_core.zig.Units.of(&self.second), &board.bus);
    }
};

fn halves(memory: Guest, at: u32, words: []const u16) !void {
    for (words, 0..) |half, i| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, half, .little);
        try memory.write(at + @as(u32, @intCast(2 * i)), &bytes);
    }
}

test "CPU1's Zig core resets from CPU1's vector table and runs its turn" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // MOVS r0, #5; ADDS r0, #1; B .
    try halves(pair.guest(), code, &.{ 0x2005, 0x3001, 0xE7FE });

    var core: SecondZig = undefined;
    try pair.bring(&core, &board);
    try std.testing.expectEqual(stack, core.cpu.regs.sp());
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, core.turn(2));
    try std.testing.expectEqual(@as(u32, 6), core.cpu.regs.get(0));
    try std.testing.expectEqual(@as(u64, 2), core.cpu.retired);
}

test "CPU1's Zig core is an M33 on the CPU1 side of the board" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();

    var core: SecondZig = undefined;
    try pair.bring(&core, &board);
    try std.testing.expectEqual(ra8.chip.core.part.cpu1_profile, core.cpu.profile);
    try std.testing.expectEqual(ra8.chip.periph.registry.Issuer.cpu1, core.board.issuer);
}

test "an MVE op on CPU1's Zig core takes UsageFault, not a step" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // VADD.I32 q0, q1, q2, then B . in each handler.
    try halves(pair.guest(), code, &.{ 0xEF22, 0x0844 });
    try halves(pair.guest(), usage_handler, &.{0xE7FE});
    try halves(pair.guest(), hard_handler, &.{0xE7FE});

    var core: SecondZig = undefined;
    try pair.bring(&core, &board);
    try core.cpu.bus.write(memmap.scb.shcsr, std.mem.asBytes(&usgfaultena));
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, core.turn(1));
    try std.testing.expectEqual(usage_handler, core.cpu.regs.pc);
    try std.testing.expectEqual(code, try pair.guest().readWord(core.cpu.regs.sp() + 24));
}

test "CPU1's Zig core polls through its own quiet source (RA8EMU-440)" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    // B . with nothing pending: the poll settles and stays settled.
    try halves(pair.guest(), code, &.{0xE7FE});

    var core: SecondZig = undefined;
    try pair.bring(&core, &board);
    try std.testing.expectEqual(&core.quiet, core.cpu.quiet.?);
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, core.turn(4));
    try std.testing.expect(core.quiet.settled);
    // A RAM store leaves the answer standing; a peripheral store stirs it.
    try core.cpu.bus.write(code + 0x100, &.{ 1, 2, 3, 4 });
    try std.testing.expect(core.quiet.settled);
    core.cpu.bus.write(0x4000_0000, &.{ 0, 0, 0, 0 }) catch {};
    try std.testing.expect(!core.quiet.settled);
}

test "CPU1's Zig core stores through its Guest into CPU1's memory (RA8EMU-535)" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var core: SecondZig = undefined;
    try pair.bring(&core, &board);
    try std.testing.expectEqual(&pair.cpu1, core.memory.store);
    try core.cpu.bus.write(code + 0x40, &.{ 0xEF, 0xBE, 0xAD, 0xDE });
    var bytes: [4]u8 = undefined;
    try pair.guest().read(code + 0x40, &bytes);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), std.mem.readInt(u32, &bytes, .little));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try core.memory.readWord(code + 0x40));
}

const store_page: usize = 0x1000;
const store_vectors: u32 = memmap.sram_base + 0x1000;
const store_stack: u32 = store_vectors + 0x800;

/// One executable PT_LOAD segment at `store_vectors`: a vector pair, then
/// MOVS r0, #5; ADDS r0, #1; B . at +0x200.
fn cpu1Image() [store_page * 2]u8 {
    const elf = ra8.board.image.elf;
    var file: [store_page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
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
        .e_entry = store_vectors + 0x201,
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
    header.* = .{ .p_type = elf.pt_load, .p_offset = store_page, .p_vaddr = store_vectors, .p_paddr = store_vectors, .p_filesz = 0x208, .p_memsz = 0x208, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[store_page..][0..4], store_stack, .little);
    std.mem.writeInt(u32, file[store_page + 4 ..][0..4], store_vectors + 0x201, .little);
    for ([_]u16{ 0x2005, 0x3001, 0xE7FE }, 0..) |half, i| {
        std.mem.writeInt(u16, file[store_page + 0x200 + 2 * i ..][0..2], half, .little);
    }
    return file;
}

test "CPU1's Zig core resets and runs over a store with no engine open" {
    var file = cpu1Image();
    const image = try ra8.board.image.elf.Image.init(&file);
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    const memory: ra8.chip.core.cpu.memory.guest.Guest = .{ .store = &store };
    const loaded = try ra8.board.image.load.read(image);
    const seeded = try second_core.seedImage(memory, loaded.image());
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var partitions = ra8.chip.periph.sau.Sau.init();
    var regions = ra8.chip.periph.mpu.Mpu.init();
    var clears = ra8.chip.periph.fault_status.clear.Clears.init();
    var core: SecondZig = undefined;
    try core.openOn(memory, .{ .partitions = &partitions, .regions = &regions, .clears = &clears, .vector_base = seeded.vector_base }, &board.bus);
    try std.testing.expectEqual(store_stack, core.cpu.regs.sp());
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, core.turn(2));
    try std.testing.expectEqual(@as(u32, 6), core.cpu.regs.get(0));
}

test "CPU1 on its own store shares CPU0's SRAM and answers as an M33" {
    var lender = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer lender.deinit();
    const shared_word: u32 = memmap.sram_base + 0x3000;
    try (ra8.chip.core.cpu.memory.guest.Guest{ .store = &lender }).writeWord(shared_word, 0x5EED_CAFE);
    var file = cpu1Image();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var own: second_core.zig.Own = undefined;
    const loaded = try ra8.board.image.load.read(try ra8.board.image.elf.Image.init(&file));
    try own.open(&lender, ra8.board.wiring.cpu1(&board), loaded.image());
    defer own.close();
    const memory = own.core.memory;
    try std.testing.expectEqual(@as(u32, 0x5EED_CAFE), try memory.readWord(shared_word));
    try std.testing.expectEqual(ra8.chip.periph.cpuid.cpu1, try memory.readWord(ra8.chip.periph.cpuid.address));
    try std.testing.expectEqual(store_stack, own.core.cpu.regs.sp());
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, own.core.turn(2));
    try std.testing.expectEqual(@as(u32, 6), own.core.cpu.regs.get(0));
}

test "RA8EMU-950: CPU1's board bus files CPACR into its own FP state" {
    var pair: Pair = undefined;
    try pair.open();
    defer pair.part();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var core: SecondZig = undefined;
    try pair.bring(&core, &board);
    try std.testing.expectEqual(&core.cpu.fp, core.board.scs.fp.?);
}
