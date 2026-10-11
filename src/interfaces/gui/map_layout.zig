//! The memory map pane's model (RA8EMU-781): every section of an image as a
//! block in the linker region it lands in, plus the stack reservation. A
//! section stored at one address and run at another (.data) gets a block at
//! each, paired so the pane can draw a line between them. No drawing here;
//! ui/map_pane.zig paints it.

const Image = @import("ra8_session").symbols.Image;
const region_map = @import("ra8_session").region.map;
const boot_slots = @import("ra8_session").boot_slots;
const sections = @import("ra8_session").sections;
const session_api = @import("ra8_session").api;

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

/// Where a core's main stack stands (RA8EMU-815), read live beside the
/// reservation the image names, so the pane can draw the SP band and the
/// overflow.
pub const Marks = struct {
    /// The main stack pointer now, and the lowest it has sat since reset.
    current: u32,
    low: u32,
    /// The reservation from the image's linker symbols.
    base: u32,
    size: u32,
    /// Whether the core has set the SP since reset.
    touched: bool = false,

    /// Bytes the lowest SP sat under the reservation's base: zero when it
    /// stayed inside, was never set, or the image names no reservation.
    pub fn overflowBytes(self: Marks) u32 {
        if (!self.touched) return 0;
        return self.base -| self.low;
    }

    pub fn overflowed(self: Marks) bool {
        return self.overflowBytes() > 0;
    }
};

pub const max_blocks = 64;

pub const Layout = struct {
    map: region_map.Map,
    blocks: [max_blocks]Block = undefined,
    count: usize = 0,
    /// The live stack marks, when a core is attached (RA8EMU-815).
    marks: ?Marks = null,
    /// The dfu boot-slot overlay, when a caller read the guest's slots (RA8EMU-778).
    slots: ?Slots = null,

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

/// One A/B slot's header state on the MRAM bar (RA8EMU-778).
pub const SlotState = struct {
    pub const State = enum { empty, valid, bad_crc };

    state: State,
    /// The header's sequence number; only meaningful when valid.
    seq: u32 = 0,

    pub fn label(self: SlotState, which: boot_slots.Which) []const u8 {
        return switch (self.state) {
            .empty => switch (which) {
                .a => "A empty",
                .b => "B empty",
            },
            .bad_crc => switch (which) {
                .a => "A bad",
                .b => "B bad",
            },
            .valid => switch (which) {
                .a => "A seq ",
                .b => "B seq ",
            },
        };
    }
};

/// The dfu A/B boot-slot overlay (RA8EMU-778): the bootloader, both slots'
/// header states, which slot the bootloader would copy to run, and the run
/// base. Populated beside the image by callers that read guest memory, and
/// left null so the pane draws nothing when the guest carries no dfu layout.
pub const Slots = struct {
    a: SlotState,
    b: SlotState,
    /// The slot the bootloader would boot, null when it stays in DFU.
    booted: ?boot_slots.Which,
    /// Where the bootloader copies the booted body, drawn on the SRAM bar.
    run_base: u32,

    /// The range in guest memory the pane outlines for a slot: start, size.
    pub fn part(which: boot_slots.Which) [2]u32 {
        return switch (which) {
            .a => .{ boot_slots.layout.slot_a_base, boot_slots.layout.slot_size },
            .b => .{ boot_slots.layout.slot_b_base, boot_slots.layout.slot_size },
        };
    }

    pub fn bootloader() [2]u32 {
        return .{ boot_slots.layout.mram_base, boot_slots.layout.bootloader_size };
    }
};

/// Reads the dfu layout out of `source` (anything with
/// `read(address: u32, into: []u8) !void` over guest memory) and returns
/// the overlay, or null when the guest carries no dfu layout: a read
/// failure, a region map that does not cover the bootloader, and no slot
/// header with the magic. `trigger_address` resolves g_dfu_trigger from the
/// image, or null to leave the trigger unknown.
pub fn slots(source: anytype, trigger_address: ?u32, regions: []const region_map.Region) ?Slots {
    const report = boot_slots.read(source, trigger_address) catch return null;
    if (region_map.regionAt(regions, boot_slots.layout.mram_base, boot_slots.layout.bootloader_size) == null) return null;
    if (!report.a.magic_ok and !report.b.magic_ok) return null;
    return .{
        .a = slotState(report.a),
        .b = slotState(report.b),
        .booted = switch (report.action) {
            .dfu => null,
            .boot_a => .a,
            .boot_b => .b,
        },
        .run_base = report.run_base,
    };
}

fn slotState(slot: boot_slots.Slot) SlotState {
    if (!slot.magic_ok) return .{ .state = .empty };
    if (slot.valid) return .{ .state = .valid, .seq = slot.header.seq };
    return .{ .state = .bad_crc };
}

/// Reads guest memory through one core's session, the source `slots` takes.
pub const SessionSource = struct {
    session: *session_api.Session,
    core: session_api.Core,

    pub fn read(self: SessionSource, address: u32, into: []u8) anyerror!void {
        try self.session.read(self.core, address, into);
    }
};
