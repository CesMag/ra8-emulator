//! The memory map pane's model (RA8EMU-781): every section of an image as a
//! block in the linker region it lands in, plus the stack reservation. A
//! section stored at one address and run at another (.data) gets a block at
//! each, paired so the pane can draw a line between them. No drawing here;
//! ui/map_pane.zig paints it.

const Image = @import("ra8_session").symbols.Image;
const region_map = @import("ra8_session").region_map;
const sections = @import("ra8_session").sections;

pub const Kind = enum { code, read_only, initialised, zero_fill, no_init, stack };

pub const Block = struct {
    name: []const u8,
    start: u32,
    size: u32,
    kind: Kind,
    region: usize,
    /// The other copy of a section stored apart from where it runs.
    pair: ?usize = null,
    /// Whether this is the stored copy of such a section, not the run copy.
    load: bool = false,

    pub fn end(self: Block) u64 {
        return @as(u64, self.start) + self.size;
    }
};

pub const max_blocks = 64;

pub const Layout = struct {
    map: region_map.Map,
    blocks: [max_blocks]Block = undefined,
    count: usize = 0,

    pub fn items(self: *const Layout) []const Block {
        return self.blocks[0..self.count];
    }

    /// The regions that hold at least one block, in region order.
    pub fn bars(self: *const Layout, into: []usize) []usize {
        var count: usize = 0;
        for (0..self.map.regions.len) |region| {
            if (count == into.len) break;
            if (!self.holds(region)) continue;
            into[count] = region;
            count += 1;
        }
        return into[0..count];
    }

    fn holds(self: *const Layout, region: usize) bool {
        for (self.items()) |block| {
            if (block.region == region) return true;
        }
        return false;
    }

    fn add(self: *Layout, block: Block) ?usize {
        if (self.count == max_blocks) return null;
        self.blocks[self.count] = block;
        self.count += 1;
        return self.count - 1;
    }

    fn place(self: *Layout, name: []const u8, start: u32, size: u32, kind: Kind) ?usize {
        const region = region_map.regionAt(self.map.regions, start, size) orelse return null;
        return self.add(.{ .name = name, .start = start, .size = size, .kind = kind, .region = region });
    }
};

/// Lay out every allocated section of `image` and its stack in `regions`.
/// Sections that fit no region are left out, as the region map counts them.
pub fn build(image: Image, regions: []const region_map.Region) region_map.Error!Layout {
    var layout = Layout{ .map = try region_map.build(image, regions) };
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const found = sections.read(image, index) orelse continue;
        if (found.size == 0) continue;
        const kind = kindOf(found.kind);
        const run = layout.place(found.name, found.vma, found.size, kind) orelse continue;
        if (!found.stored() or found.lma == found.vma) continue;
        const load = layout.place(found.name, found.lma, found.size, kind) orelse continue;
        layout.blocks[load].load = true;
        layout.blocks[load].pair = run;
        layout.blocks[run].pair = load;
    }
    if (layout.map.stack) |stack| _ = layout.place("stack", stack.base, stack.size, .stack);
    return layout;
}

fn kindOf(kind: sections.Kind) Kind {
    return switch (kind) {
        .code => .code,
        .read_only => .read_only,
        .initialised => .initialised,
        .zero_fill => .zero_fill,
        .no_init => .no_init,
    };
}
