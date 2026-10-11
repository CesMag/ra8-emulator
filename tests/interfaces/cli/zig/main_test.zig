//! Covers src/interfaces/cli/zig/main.zig: a `--cpu zig` run from main with
//! no engine opened (RA8EMU-592).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const memmap = ra8.chip.core.memmap;
const elf = ra8.board.image.elf;
const main_path = cli_app.zig.run.main_path;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const Parts = cli_app.parts.Parts;

const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const stack: u32 = memmap.sram_base + 0x800;

/// One executable PT_LOAD segment in code MRAM: SP, reset, then B . at +8.
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

test "prepare loads CPU0 onto its own store with no engine behind it" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var file = image();
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    const written = try main_path.prepare(&cpu0, &board, std.testing.io, try elf.Image.init(&file), &parts, .{ .path = "cpu0.elf", .cpu = .zig, .ctl_cpu_load = true });
    try std.testing.expectEqual(@as(u32, 0xC), written);
    const memory = cpu0.own();
    try std.testing.expectEqual(stack, try memory.readWord(vectors));
    try std.testing.expectEqual(vectors + 9, try memory.readWord(vectors + 4));
    try std.testing.expectEqual(ra8.chip.periph.cpuid.cpu0, try memory.readWord(ra8.chip.periph.cpuid.address));
}

test "fit puts the command line's part on the board" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    const options: cli_app.cli.Options = .{ .path = "cpu0.elf", .cpu = .zig };
    try main_path.fit(&board, std.testing.allocator, std.testing.io, options);
    try std.testing.expectEqual(options.part, board.part);
}
