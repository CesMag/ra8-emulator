//! A minimal ELF32 ARM image carrying one symbol table, built byte by byte
//! so a test owns every offset in it. Shared by the symbol reader's tests
//! and by the report tests that resolve a global through it.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const symbols = ra8.session.symbols;

/// A minimal ELF32 ARM image with one symbol table and one string table,
/// built byte by byte so the test owns every offset in it.
pub const Builder = struct {
    /// Layout: header, then three section headers, then the two tables.
    pub const header_len = @sizeOf(elf.Header);
    pub const shent = @sizeOf(symbols.SectionHeader);
    pub const sh_count = 3;
    pub const sh_off = header_len;
    pub const sym_off = sh_off + shent * sh_count;

    pub fn build(buffer: []u8, names: []const []const u8, values: []const u32) []u8 {
        @memset(buffer, 0);
        // The string table: a leading null, then each name terminated.
        var strings: std.ArrayListUnmanaged(u8) = .empty;
        var offsets: [8]u32 = undefined;
        var backing: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&backing);
        strings.append(fba.allocator(), 0) catch unreachable;
        for (names, 0..) |name, index| {
            offsets[index] = @intCast(strings.items.len);
            strings.appendSlice(fba.allocator(), name) catch unreachable;
            strings.append(fba.allocator(), 0) catch unreachable;
        }
        const sym_len = @sizeOf(symbols.Symbol) * names.len;
        const str_off = sym_off + sym_len;

        const head: *align(1) elf.Header = std.mem.bytesAsValue(elf.Header, buffer[0..header_len]);
        head.magic = .{ 0x7F, 'E', 'L', 'F' };
        head.class = 1;
        head.data = 1;
        head.e_machine = elf.em_arm;
        head.e_shoff = sh_off;
        head.e_shentsize = shent;
        head.e_shnum = sh_count;
        head.e_phnum = 0;

        // Section 1 is the symbol table, linking to section 2, the strings.
        const one: *align(1) symbols.SectionHeader =
            std.mem.bytesAsValue(symbols.SectionHeader, buffer[sh_off + shent ..][0..shent]);
        one.sh_type = symbols.section_type.symtab;
        one.sh_offset = sym_off;
        one.sh_size = @intCast(sym_len);
        one.sh_entsize = @sizeOf(symbols.Symbol);
        one.sh_link = 2;

        const two: *align(1) symbols.SectionHeader =
            std.mem.bytesAsValue(symbols.SectionHeader, buffer[sh_off + shent * 2 ..][0..shent]);
        two.sh_type = 3;
        two.sh_offset = @intCast(str_off);
        two.sh_size = @intCast(strings.items.len);

        for (names, 0..) |_, index| {
            const at = sym_off + @sizeOf(symbols.Symbol) * index;
            const entry: *align(1) symbols.Symbol =
                std.mem.bytesAsValue(symbols.Symbol, buffer[at..][0..@sizeOf(symbols.Symbol)]);
            entry.st_name = offsets[index];
            entry.st_value = values[index];
        }
        @memcpy(buffer[str_off..][0..strings.items.len], strings.items);
        return buffer[0 .. str_off + strings.items.len];
    }
};
