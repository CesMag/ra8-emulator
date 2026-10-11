//! A ThreadX module's symbols, moved to where the Module Manager loaded it
//! (RA8EMU-1141, part of RA8EMU-1084).
//!
//! A module ELF is linked at a fixed base (txm_hello_m33 puts its preamble
//! and code at 0x30000), but the manager copies the code to wherever it
//! allocates, and records that address as the instance's code_start
//! (txm.modules.offset.code_start). Every code address in the ELF is then
//! off by the same amount: code_start minus the base of the ELF's
//! executable load segment. A name looked up here comes back where the
//! guest really runs it, and a guest PC maps back to the ELF's own name.
//!
//! Only code moves here. Data reached through the module's own base
//! register is a later slice of 1141, so a data symbol gives null rather
//! than an address that would be wrong.
const elf = @import("ra8_board").image.elf;
const symbols = @import("../symbols.zig");

/// One loaded module: its ELF, where it was linked, and where it runs.
pub const Module = struct {
    image: elf.Image,
    /// The vaddr of the ELF's executable load segment.
    link_code: u32,
    /// How much of the ELF moves with it: that segment's memory size.
    link_size: u32,
    /// Where the manager placed the code (the instance's code_start).
    code_start: u32,

    /// The module `image` running at `code_start`, or null when the image
    /// has no executable load segment to move.
    pub fn at(image: elf.Image, code_start: u32) ?Module {
        const code = codeSegment(image) orelse return null;
        return .{ .image = image, .link_code = code.vaddr, .link_size = code.memsz, .code_start = code_start };
    }

    /// Where the guest runs the code symbol `name`, or null when the ELF
    /// does not name it or it is not in the moved segment. A Thumb
    /// function keeps its interworking bit.
    pub fn addressOf(self: Module, name: []const u8) ?u32 {
        const linked = symbols.addressOf(self.image, name) orelse return null;
        if (!self.linkedCode(linked & ~@as(u32, 1))) return null;
        return linked -% self.link_code +% self.code_start;
    }

    /// The module function a guest address falls inside, or null when the
    /// address is outside the module's code or no sized function covers it.
    pub fn inside(self: Module, address: u32) ?symbols.Inside {
        if (address < self.code_start or address - self.code_start >= self.link_size) return null;
        return symbols.inside(self.image, address - self.code_start + self.link_code);
    }

    fn linkedCode(self: Module, linked: u32) bool {
        return linked >= self.link_code and linked - self.link_code < self.link_size;
    }
};

/// The first executable load segment of `image`, the part the manager
/// moves as the module's code.
pub fn codeSegment(image: elf.Image) ?elf.Segment {
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (segment.flags & elf.pf_x != 0) return segment;
    }
    return null;
}
