//! Covers src/chip/core/cpu/memory/load.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const elf = ra8.board.image.elf;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const load = ra8.chip.core.cpu.memory.load;

const page: usize = 0x1000;

/// An image of `count` PT_LOAD segments, the first at MRAM (a vector pair)
/// and the second at SRAM (a marker word), each from its own file page.
fn twoSegments(count: u16) [page * 3]u8 {
    var file: [page * 3]u8 align(@alignOf(elf.Header)) = @splat(0);
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
        .e_entry = memmap.mram_base + 0x101,
        .e_phoff = @sizeOf(elf.Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Header),
        .e_phentsize = @sizeOf(elf.ProgramHeader),
        .e_phnum = count,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const at = [_]u32{ memmap.mram_base, memmap.sram_base + 0x200 };
    for (at[0..count], 0..) |where, i| {
        const header: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header) + i * @sizeOf(elf.ProgramHeader)]));
        header.* = .{ .p_type = elf.pt_load, .p_offset = @intCast(page * (i + 1)), .p_vaddr = where, .p_paddr = where, .p_filesz = 8, .p_memsz = 8, .p_flags = 4, .p_align = 4 };
    }
    std.mem.writeInt(u32, file[page..][0..4], memmap.sram_base + 0x8000, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], memmap.mram_base + 0x101, .little);
    std.mem.writeInt(u32, file[page * 2 ..][0..4], 0x5EED_C0DE, .little);
    return file;
}

test "an image loads into the Zig core's store with no engine open" {
    var file = twoSegments(2);
    const image = try elf.Image.init(&file);
    var store = try Store.init(null);
    defer store.deinit();
    const memory: Guest = .{ .store = &store };
    const loaded = try ra8.board.image.load.read(image);
    try std.testing.expectEqual(@as(u32, 16), try load.image(memory, loaded.image()));
    try std.testing.expectEqual(memmap.sram_base + 0x8000, try memory.readWord(memmap.mram_base));
    try std.testing.expectEqual(memmap.mram_base + 0x101, try memory.readWord(memmap.mram_base + 4));
    try std.testing.expectEqual(@as(u32, 0x5EED_C0DE), try memory.readWord(memmap.sram_base + 0x200));
}

test "an image with nothing to load is refused" {
    var file = twoSegments(0);
    const image = try elf.Image.init(&file);
    var store = try Store.init(null);
    defer store.deinit();
    const loaded = try ra8.board.image.load.read(image);
    try std.testing.expectError(load.Error.WriteFailed, load.image(.{ .store = &store }, loaded.image()));
}
