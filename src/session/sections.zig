//! The section table of a firmware image: what each allocated section is,
//! where it runs (VMA), where it is stored (LMA), and what startup does
//! with it. The same answer `objdump -h` gives, read without a toolchain.
//!
//! WHAT IT IS FOR. A memory-layout view needs to place every section in the
//! linker's regions, and .data is the case that makes that hard: it runs in
//! SRAM but is stored in MRAM, so it takes room in both. That second address
//! is not in the section header. It comes from the PT_LOAD segment that
//! carries the section, so this file joins the two tables.
//!
//! ONLY ALLOCATED SECTIONS. Debug, comment and attribute sections have no
//! target address and take no target memory, so they are not listed.
//!
//! NO-INIT IS A NAME. .bss and .noinit are both SHT_NOBITS and writable;
//! nothing in the ELF separates them. Startup zeroes .bss by its linker
//! symbols and leaves .noinit alone, and the firmware's linker script names
//! the section .noinit, so a section of that name (or .noinit.*) reads as
//! no-init and any other NOBITS section as zero-fill.
//!
//! Like symbols.zig, nothing here allocates and every read is bounds-checked,
//! so a truncated or hostile image gives fewer sections, never a bad slice.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const symbols = @import("symbols.zig");

/// The section header fields this table reads.
pub const header = struct {
    /// SHT_NOBITS: the section takes memory but no file bytes.
    pub const nobits: u32 = 8;
    /// SHF_WRITE.
    pub const write: u32 = 0x1;
    /// SHF_ALLOC: the section occupies target memory.
    pub const alloc: u32 = 0x2;
    /// SHF_EXECINSTR.
    pub const exec: u32 = 0x4;
};

/// What startup does with a section's memory.
pub const Kind = enum {
    /// Executable instructions, stored and run in place.
    code,
    /// Constants, stored and read in place.
    read_only,
    /// Writable data copied from its LMA to its VMA at startup.
    initialised,
    /// Writable memory startup zeroes, with no stored bytes.
    zero_fill,
    /// Writable memory startup leaves alone, so it survives a warm reset.
    no_init,
};

/// One allocated section.
pub const Section = struct {
    name: []const u8,
    /// Where the section lives while the firmware runs.
    vma: u32,
    /// Where its bytes are stored in the image (VMA when nothing is copied).
    lma: u32,
    size: u32,
    kind: Kind,

    /// Whether the section takes storage apart from where it runs, as .data
    /// does: stored at its LMA, copied to its VMA.
    pub fn stored(self: Section) bool {
        return self.kind != .zero_fill and self.kind != .no_init;
    }
};

/// How many allocated sections the image carries.
pub fn count(image: elf.Image) usize {
    var total: usize = 0;
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        if (read(image, index) != null) total += 1;
    }
    return total;
}

/// Fill `into` with the image's allocated sections in header order and
/// return how many were written; a short buffer keeps the first ones.
pub fn list(image: elf.Image, into: []Section) usize {
    var written: usize = 0;
    var index: u16 = 0;
    while (index < image.header().e_shnum and written < into.len) : (index += 1) {
        into[written] = read(image, index) orelse continue;
        written += 1;
    }
    return written;
}

/// The allocated section of a name, or null when the image has none.
pub fn byName(image: elf.Image, wanted: []const u8) ?Section {
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const found = read(image, index) orelse continue;
        if (std.mem.eql(u8, found.name, wanted)) return found;
    }
    return null;
}

/// The section at a header index, or null when it is not an allocated one.
pub fn read(image: elf.Image, index: u16) ?Section {
    const head = symbols.section(image, index) orelse return null;
    if (head.sh_flags & header.alloc == 0 or head.sh_type == 0) return null;
    const name = nameOf(image, head.sh_name);
    return .{
        .name = name,
        .vma = head.sh_addr,
        .lma = lmaOf(image, head) orelse head.sh_addr,
        .size = head.sh_size,
        .kind = kindOf(head, name),
    };
}

fn kindOf(head: *align(1) const symbols.SectionHeader, name: []const u8) Kind {
    if (head.sh_type == header.nobits) {
        const no_init = std.mem.eql(u8, name, ".noinit") or std.mem.startsWith(u8, name, ".noinit.");
        return if (no_init) .no_init else .zero_fill;
    }
    if (head.sh_flags & header.exec != 0) return .code;
    if (head.sh_flags & header.write != 0) return .initialised;
    return .read_only;
}

/// The load address of a section, through the PT_LOAD that carries it: by
/// file offset for a section with contents, by run address for NOBITS.
fn lmaOf(image: elf.Image, head: *align(1) const symbols.SectionHeader) ?u32 {
    var index: u16 = 0;
    while (index < image.header().e_phnum) : (index += 1) {
        const ph = program(image, index) orelse continue;
        if (ph.p_type != elf.pt_load) continue;
        if (head.sh_type == header.nobits) {
            const from = @as(u64, ph.p_vaddr);
            if (head.sh_addr < from or head.sh_addr >= from + ph.p_memsz) continue;
            return ph.p_paddr +% (head.sh_addr - ph.p_vaddr);
        }
        const from = @as(u64, ph.p_offset);
        const to = @as(u64, head.sh_offset) + head.sh_size;
        if (head.sh_offset < from or to > from + ph.p_filesz) continue;
        return ph.p_paddr +% (head.sh_offset - ph.p_offset);
    }
    return null;
}

/// One bounds-checked program header of any type.
fn program(image: elf.Image, index: u16) ?*align(1) const elf.ProgramHeader {
    const head = image.header();
    if (head.e_phentsize < @sizeOf(elf.ProgramHeader)) return null;
    const start = @as(usize, head.e_phoff) + @as(usize, index) * @as(usize, head.e_phentsize);
    if (start + @sizeOf(elf.ProgramHeader) > image.bytes.len) return null;
    return std.mem.bytesAsValue(elf.ProgramHeader, image.bytes[start..][0..@sizeOf(elf.ProgramHeader)]);
}

/// A section's name from the section-name string table, empty when the
/// table or the offset is out of range.
fn nameOf(image: elf.Image, offset: u32) []const u8 {
    const names = symbols.section(image, image.header().e_shstrndx) orelse return "";
    const from = @as(usize, names.sh_offset);
    const to = from + @as(usize, names.sh_size);
    if (to > image.bytes.len or offset >= names.sh_size) return "";
    const strings = image.bytes[from..to];
    const end = std.mem.indexOfScalarPos(u8, strings, offset, 0) orelse return "";
    return strings[offset..end];
}
