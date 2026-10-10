//! A one-segment ELF image for the undefined-instruction tests: the sweep's
//! own (tests/chip/core/undefined_ops_test.zig) and the report's
//! (tests/interfaces/cli/report/undefined_test.zig).
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;

/// An ELF32 ARM image carrying one executable segment of the given bytes.
pub fn imageWith(buffer: []u8, code: []const u8, vaddr: u32) elf.Image {
    @memset(buffer, 0);
    const head = std.mem.bytesAsValue(elf.Header, buffer[0..@sizeOf(elf.Header)]);
    @memcpy(&head.magic, "\x7fELF");
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 1;
    const at = @as(usize, head.e_phoff);
    const ph = std.mem.bytesAsValue(elf.ProgramHeader, buffer[at..][0..@sizeOf(elf.ProgramHeader)]);
    ph.p_type = elf.pt_load;
    ph.p_flags = elf.pf_x;
    ph.p_offset = @intCast(at + @sizeOf(elf.ProgramHeader));
    ph.p_vaddr = vaddr;
    ph.p_paddr = vaddr;
    ph.p_filesz = @intCast(code.len);
    ph.p_memsz = @intCast(code.len);
    @memcpy(buffer[ph.p_offset..][0..code.len], code);
    return elf.Image.init(buffer) catch unreachable;
}
