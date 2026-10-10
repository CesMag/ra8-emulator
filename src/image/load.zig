//! An ELF image read into the chip's loaded-image value (RA8EMU-1039,
//! ADR 0004). src/image parses the format; the chip only writes what this
//! hands it. The value's slices point into the ELF bytes and into the
//! `Loaded` that holds them, so both outlive the load.
const elf = @import("elf.zig");
const pages = @import("pages.zig");
const loaded_image = @import("ra8_chip").core.loaded_image;

/// Load segments with file bytes one image may carry.
pub const capacity: usize = 32;

pub const Error = error{TooManySegments} || pages.Error;

pub const Loaded = struct {
    segments: [capacity]loaded_image.Segment = undefined,
    count: usize = 0,
    maps: pages.Set = .{},
    vector_base: ?u32 = null,

    pub fn image(self: *const Loaded) loaded_image.Image {
        return .{
            .segments = self.segments[0..self.count],
            .maps = self.maps.items(),
            .vector_base = self.vector_base,
        };
    }
};

/// The segments, merged pages and vector table of `source`.
pub fn read(source: elf.Image) Error!Loaded {
    var loaded = Loaded{ .maps = try pages.forImage(source), .vector_base = source.vectorBase() };
    var index: u16 = 0;
    while (index < source.segmentCount()) : (index += 1) {
        const segment = source.loadSegment(index) orelse continue;
        if (loaded.count == capacity) return Error.TooManySegments;
        loaded.segments[loaded.count] = segment;
        loaded.count += 1;
    }
    return loaded;
}
