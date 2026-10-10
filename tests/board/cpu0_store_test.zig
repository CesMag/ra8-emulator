//! Covers src/board/cpu0_store.zig: CPU0 on its own store for a
//! single-core `--cpu zig` run (RA8EMU-580).
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.chip.core.memmap;
const elf = ra8.board.image.elf;
const Cpu0 = ra8.board.cpu0_store.Cpu0;

const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const stack: u32 = memmap.sram_base + 0x800;

/// One executable PT_LOAD segment in code MRAM, where a real image loads:
/// SP, reset, then B . at +8.
fn image() [page * 2]u8 {
    var file: [page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
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
        .e_entry = vectors + 9,
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
    header.* = .{ .p_type = elf.pt_load, .p_offset = page, .p_vaddr = vectors, .p_paddr = vectors, .p_filesz = 0xC, .p_memsz = 0xC, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[page..][0..4], stack, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], vectors + 9, .little);
    std.mem.writeInt(u16, file[page + 8 ..][0..2], 0xE7FE, .little);
    return file;
}

test "a single-core zig run loads CPU0 into its own store" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var file = image();
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    _ = try cpu0.attachStore(&board, try elf.Image.init(&file));
    const memory = cpu0.own();
    try std.testing.expectEqual(&cpu0.store.?, memory.store);
    try std.testing.expectEqual(stack, try memory.readWord(vectors));
    try std.testing.expectEqual(ra8.chip.periph.cpuid.cpu0, try memory.readWord(ra8.chip.periph.cpuid.address));
    // The whole option window is mapped, its last page included, with room
    // left for an image page outside memmap.
    _ = try memory.readWord(0x02E1_79F0);
    try memory.map(0x02C9_F000, 0x1000);
}
