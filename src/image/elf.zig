//! ELF32 image services.
//!
//! The C original walked the file with named byte offsets because it parsed
//! straight out of a byte buffer. Zig reads the same layout as extern structs,
//! so the offsets are the struct fields and the bounds checks are slices.
const std = @import("std");
const memmap = @import("ra8_chip").core.memmap;
const loaded_image = @import("ra8_chip").core.loaded_image;

pub const Error = error{
    NotElf32,
    NotLittleEndian,
    NotArm,
    Truncated,
    NoLoadableSegment,
};

pub const em_arm: u16 = 40;
pub const pt_load: u32 = 1;
pub const pf_x: u32 = 1;

pub const Header = extern struct {
    magic: [4]u8,
    class: u8,
    data: u8,
    version: u8,
    osabi: u8,
    abiversion: u8,
    pad: [7]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const ProgramHeader = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

/// A load segment, in the chip's own shape (RA8EMU-1039).
pub const Segment = loaded_image.Segment;

/// An immutable view of a firmware image, the Zig shape of emu_elf_source_t.
pub const Image = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Error!Image {
        if (bytes.len < @sizeOf(Header)) return Error.Truncated;
        const head = std.mem.bytesAsValue(Header, bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &head.magic, "\x7fELF")) return Error.NotElf32;
        if (head.class != 1) return Error.NotElf32;
        if (head.data != 1) return Error.NotLittleEndian;
        if (head.e_machine != em_arm) return Error.NotArm;
        return .{ .bytes = bytes };
    }

    pub fn header(self: Image) *align(1) const Header {
        return std.mem.bytesAsValue(Header, self.bytes[0..@sizeOf(Header)]);
    }

    pub fn segmentCount(self: Image) u16 {
        return self.header().e_phnum;
    }

    /// One bounds-checked PT_LOAD segment, or null when the index is not one.
    pub fn loadSegment(self: Image, index: u16) ?Segment {
        const head = self.header();
        if (index >= head.e_phnum) return null;
        if (head.e_phentsize < @sizeOf(ProgramHeader)) return null;
        const start = @as(usize, head.e_phoff) + @as(usize, index) * @as(usize, head.e_phentsize);
        if (start + @sizeOf(ProgramHeader) > self.bytes.len) return null;
        const ph: *align(1) const ProgramHeader = std.mem.bytesAsValue(ProgramHeader, self.bytes[start..][0..@sizeOf(ProgramHeader)]);
        if (ph.p_type != pt_load or ph.p_filesz == 0) return null;
        const from = @as(usize, ph.p_offset);
        const to = from + @as(usize, ph.p_filesz);
        if (to > self.bytes.len) return null;
        return .{
            .vaddr = ph.p_vaddr,
            .paddr = ph.p_paddr,
            .flags = ph.p_flags,
            .bytes = self.bytes[from..to],
            .memsz = ph.p_memsz,
        };
    }

    /// Find the load segment that contains the initial stack and Thumb reset
    /// vectors. Linkers commonly keep this read-only table in a separate
    /// segment from the executable code it points to.
    pub fn vectorBase(self: Image) ?u32 {
        var index: u16 = 0;
        while (index < self.segmentCount()) : (index += 1) {
            const segment = self.loadSegment(index) orelse continue;
            if (segment.bytes.len < 8 or segment.memsz < 8) continue;
            const stack_pointer = std.mem.readInt(u32, segment.bytes[0..4], .little);
            const reset_vector = std.mem.readInt(u32, segment.bytes[4..8], .little);
            if (!validStackPointer(stack_pointer)) continue;
            if (!self.executableAddress(reset_vector)) continue;
            return segment.vaddr;
        }
        return null;
    }

    fn executableAddress(self: Image, reset_vector: u32) bool {
        if (reset_vector & 1 == 0) return false;
        const address = reset_vector & ~@as(u32, 1);
        var index: u16 = 0;
        while (index < self.segmentCount()) : (index += 1) {
            const segment = self.loadSegment(index) orelse continue;
            if (!segment.executable()) continue;
            const start: u64 = segment.vaddr;
            const end = start + segment.memsz;
            if (address >= start and @as(u64, address) < end) return true;
        }
        return false;
    }
};

fn validStackPointer(stack_pointer: u32) bool {
    if (stack_pointer & 7 != 0) return false;
    for (memmap.ram) |region| {
        // A stack never lives in instruction TCM or the PPB.
        if (region.base == memmap.itcm_base or region.base == memmap.ppb_base) continue;
        if (!region.perms.write) continue;
        if (stack_pointer > region.base and @as(u64, stack_pointer) <= region.end()) return true;
    }
    return false;
}
