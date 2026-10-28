//! The symbol table of a firmware image: a global's address, by name.
//!
//! elf.zig loads an image, which needs the program headers and nothing else.
//! This is the other half of the file, the part a debugger reads: the section
//! headers, the symbol table one of them holds, and the string table it
//! names. Kept separate because loading and inspecting are two purposes, and
//! only one of them runs on every image.
//!
//! WHAT IT IS FOR. The firmware's own emulator-in-the-loop suite checks 29 of
//! its 122 apps by reading one global after the run: scripts/emu/eil_all.sh
//! verdict_memprobe asks for `--dump-sym <sym> --stop-sym <sym> <N>`, where
//! the symbol is a progress counter the app advances. On hardware the same
//! number comes back over J-Link. There is no way to answer that without
//! resolving a name to an address, so this is the floor under any run of
//! that suite against this emulator.
//!
//! A LOOKUP IS A SEARCH, NOT AN INDEX. Nothing here builds a map: an image
//! carries a few thousand symbols and a run asks for two or three, so the
//! walk is cheaper than the table it would build, and it needs no allocator.
//! Every read is bounds-checked against the image's own bytes, so a
//! truncated or hostile table gives null rather than a slice out of range.
const std = @import("std");
const elf = @import("ra8_board").image.elf;

/// The parsed image every lookup here reads: the board loader's ELF image.
/// A caller that holds one names it through the session.
pub const Image = elf.Image;

/// Section header types, of which only the symbol table matters here.
pub const section_type = struct {
    /// SHT_SYMTAB, the full symbol table a linked image keeps.
    pub const symtab: u32 = 2;
};

/// Symbol types, of which only the function matters here.
pub const symbol_type = struct {
    /// STT_FUNC, the low nibble of st_info on a function symbol.
    pub const func: u8 = 2;
};

/// One ELF32 section header, read straight off the file.
pub const SectionHeader = extern struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u32,
    sh_addr: u32,
    sh_offset: u32,
    sh_size: u32,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u32,
    sh_entsize: u32,
};

/// One ELF32 symbol table entry.
pub const Symbol = extern struct {
    st_name: u32,
    st_value: u32,
    st_size: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
};

/// The two tables a lookup needs: the symbols, and the strings they name.
const Tables = struct {
    symbols: []const u8,
    strings: []const u8,
    entry_size: usize,
};

/// One bounds-checked section header, or null when the index is not one.
pub fn section(image: elf.Image, index: u16) ?*align(1) const SectionHeader {
    const head = image.header();
    if (index >= head.e_shnum) return null;
    if (head.e_shentsize < @sizeOf(SectionHeader)) return null;
    const start = @as(usize, head.e_shoff) + @as(usize, index) * @as(usize, head.e_shentsize);
    const stop = start + @sizeOf(SectionHeader);
    if (stop > image.bytes.len) return null;
    return std.mem.bytesAsValue(SectionHeader, image.bytes[start..][0..@sizeOf(SectionHeader)]);
}

/// The bytes a section covers, bounds-checked against the image.
fn contents(image: elf.Image, head: *align(1) const SectionHeader) ?[]const u8 {
    const from = @as(usize, head.sh_offset);
    const to = from + @as(usize, head.sh_size);
    if (to > image.bytes.len or from > to) return null;
    return image.bytes[from..to];
}

/// The symbol table and its string table, or null when the image carries
/// none. A stripped image is the ordinary case for that, not a fault.
fn tables(image: elf.Image) ?Tables {
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const head = section(image, index) orelse continue;
        if (head.sh_type != section_type.symtab) continue;
        const entry_size = if (head.sh_entsize == 0) @sizeOf(Symbol) else @as(usize, head.sh_entsize);
        if (entry_size < @sizeOf(Symbol)) continue;
        const symbols = contents(image, head) orelse continue;
        // sh_link on a symbol table is the string table it names into.
        if (head.sh_link >= image.header().e_shnum) continue;
        const names = section(image, @intCast(head.sh_link)) orelse continue;
        const strings = contents(image, names) orelse continue;
        return .{ .symbols = symbols, .strings = strings, .entry_size = entry_size };
    }
    return null;
}

/// The name at an offset into the string table, up to its terminator. The
/// table is C strings on the wire, so this is the one place a null-terminated
/// string is read, and it comes straight back out as a slice.
fn nameAt(strings: []const u8, offset: u32) ?[]const u8 {
    if (offset >= strings.len) return null;
    const rest = strings[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

/// Where the global called `wanted` lives, or null when the image does not
/// name it. A symbol whose value is zero is reported as found at zero rather
/// than as missing: the caller decides what an address of zero means.
pub fn addressOf(image: elf.Image, wanted: []const u8) ?u32 {
    const found = tables(image) orelse return null;
    var offset: usize = 0;
    while (offset + @sizeOf(Symbol) <= found.symbols.len) : (offset += found.entry_size) {
        const entry: *align(1) const Symbol =
            std.mem.bytesAsValue(Symbol, found.symbols[offset..][0..@sizeOf(Symbol)]);
        const name = nameAt(found.strings, entry.st_name) orelse continue;
        if (std.mem.eql(u8, name, wanted)) return entry.st_value;
    }
    return null;
}

/// The first image in `images` that names `wanted`, read in order.
///
/// A TrustZone run loads two images: the secure one owns the vectors and the
/// Non-Secure one is copied in beside it. A global the Non-Secure side keeps
/// lives only in the second symbol table, so a lookup that should find
/// either asks both, secure first.
pub fn addressInAny(images: []const elf.Image, wanted: []const u8) ?u32 {
    for (images) |image| {
        if (addressOf(image, wanted)) |address| return address;
    }
    return null;
}

/// A named function: where its first instruction is, and how long it is.
pub const Extent = struct {
    address: u32,
    size: u32,
};

/// The function called `wanted`, or null when the image names no sized
/// function by that name.
///
/// A Thumb function's st_value carries the interworking bit, so the address
/// of its first instruction is st_value with bit 0 cleared. A zero-sized
/// symbol is refused rather than reported with a length of nothing: a
/// caller asking for an extent wants somewhere to look, and guessing one
/// from the next symbol along would put a wrong length on a real function.
pub fn extentOf(image: elf.Image, wanted: []const u8) ?Extent {
    const found = tables(image) orelse return null;
    var offset: usize = 0;
    while (offset + @sizeOf(Symbol) <= found.symbols.len) : (offset += found.entry_size) {
        const entry: *align(1) const Symbol =
            std.mem.bytesAsValue(Symbol, found.symbols[offset..][0..@sizeOf(Symbol)]);
        if (entry.st_info & 0xF != symbol_type.func) continue;
        if (entry.st_size == 0) continue;
        const name = nameAt(found.strings, entry.st_name) orelse continue;
        if (!std.mem.eql(u8, name, wanted)) continue;
        return .{ .address = entry.st_value & ~@as(u32, 1), .size = entry.st_size };
    }
    return null;
}

/// Copy sized function ranges into caller storage, in symbol table order.
/// Returns the number copied; excess symbols are deliberately omitted.
pub fn functionExtents(image: elf.Image, into: []Extent) usize {
    const found = tables(image) orelse return 0;
    var written: usize = 0;
    var offset: usize = 0;
    while (offset + @sizeOf(Symbol) <= found.symbols.len and written < into.len) : (offset += found.entry_size) {
        const entry: *align(1) const Symbol = std.mem.bytesAsValue(Symbol, found.symbols[offset..][0..@sizeOf(Symbol)]);
        if (entry.st_info & 0xF != symbol_type.func or entry.st_size == 0) continue;
        into[written] = .{ .address = entry.st_value & ~@as(u32, 1), .size = entry.st_size };
        written += 1;
    }
    return written;
}

/// How many symbols the image carries, for a report that wants to say the
/// table was read rather than guessed at.
pub fn count(image: elf.Image) usize {
    const found = tables(image) orelse return 0;
    return found.symbols.len / found.entry_size;
}

/// A function symbol and how far into it an address sits.
pub const Inside = struct {
    name: []const u8,
    offset: u32,
};

/// The function an address falls inside, or null when no function symbol
/// covers it.
///
/// A Thumb function's st_value carries the interworking bit, so the byte
/// address of its first instruction is st_value with bit 0 cleared; an
/// address is compared against that, never against the raw value. Only
/// sized function symbols are considered: a zero-sized symbol says where
/// something starts and nothing about where it ends, and guessing an extent
/// from the next symbol along would put a wrong name on a real address.
///
/// The greatest covering base wins, so a symbol nested inside another is
/// reported rather than its container.
pub fn inside(image: elf.Image, address: u32) ?Inside {
    const found = tables(image) orelse return null;
    var best: ?Inside = null;
    var best_base: u32 = 0;
    var offset: usize = 0;
    while (offset + @sizeOf(Symbol) <= found.symbols.len) : (offset += found.entry_size) {
        const entry: *align(1) const Symbol =
            std.mem.bytesAsValue(Symbol, found.symbols[offset..][0..@sizeOf(Symbol)]);
        if (entry.st_info & 0xF != symbol_type.func) continue;
        if (entry.st_size == 0) continue;
        const base = entry.st_value & ~@as(u32, 1);
        if (address < base or address >= base +% entry.st_size) continue;
        if (best != null and base <= best_base) continue;
        const name = nameAt(found.strings, entry.st_name) orelse continue;
        best = .{ .name = name, .offset = address - base };
        best_base = base;
    }
    return best;
}

/// A symbol as the table names it.
pub const Named = struct {
    name: []const u8,
    value: u32,
    size: u32,
    kind: u8,
};

/// Walks every named symbol of an image in table order; an image with no
/// symbol table walks nothing.
pub const Walk = struct {
    found: ?Tables,
    offset: usize = 0,

    pub fn init(image: elf.Image) Walk {
        return .{ .found = tables(image) };
    }

    pub fn next(self: *Walk) ?Named {
        const tab = self.found orelse return null;
        while (self.offset + @sizeOf(Symbol) <= tab.symbols.len) {
            const entry: *align(1) const Symbol = std.mem.bytesAsValue(Symbol, tab.symbols[self.offset..][0..@sizeOf(Symbol)]);
            self.offset += tab.entry_size;
            const name = nameAt(tab.strings, entry.st_name) orelse continue;
            return .{ .name = name, .value = entry.st_value, .size = entry.st_size, .kind = entry.st_info & 0xF };
        }
        return null;
    }
};
