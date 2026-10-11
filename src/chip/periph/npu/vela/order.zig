//! The order Vela lays a convolution's weights out in, undone: a decoded
//! weight stream back to the OHWI volume (output channel, kernel row,
//! kernel column, input channel) the model holds.
//!
//! WHAT: the walk in Vela 3.12.0's mlw_codec `reorder` (mlw_encode.c), run
//! in the other direction. Weights go in OFM-depth blocks, then IFM-depth
//! blocks, then 8x8 sub-kernels, then micro-blocks, with zero padding
//! wherever a block runs past the volume's edge.
//! WHY: the weight stream (weights.zig) only gives the values;
//! a convolution needs to know which output, tap and input each one is for.
const std = @import("std");

pub const Error = error{ BadShape, ShortStream, LongStream };

/// Which way the hardware traverses the kernel, from Vela's
/// NpuBlockTraversal plus the depthwise case.
pub const Traversal = enum { depth_first, part_kernel_first, depthwise };

/// The weight volume and the block sizes it was encoded for. The defaults
/// are the Ethos-U55-256's micro-blocks (8 deep) and Vela's 8x8 sub-kernel
/// limit at dilation 1.
pub const Layout = struct {
    ofm_depth: u32,
    kernel_height: u32,
    kernel_width: u32,
    ifm_depth: u32,
    ofm_block_depth: u32,
    traversal: Traversal = .depth_first,
    ifm_bitdepth: u32 = 8,
    ifm_ublock_depth: u32 = 8,
    ofm_ublock_depth: u32 = 8,
    decomp_h: u32 = 8,
    decomp_w: u32 = 8,

    /// How many weights the volume holds.
    pub fn volume(self: Layout) usize {
        return @as(usize, self.ofm_depth) * self.kernel_height * self.kernel_width * self.ifm_depth;
    }

    fn valid(self: Layout) bool {
        return self.volume() > 0 and self.ofm_block_depth > 0 and self.ifm_ublock_depth > 0 and
            self.ofm_ublock_depth > 0 and self.decomp_h > 0 and self.decomp_w > 0;
    }
};

/// Place `stream`, decoded weights in Vela's order, into `ohwi`. The
/// stream must be exactly as long as the padded walk.
pub fn unpack(layout: Layout, stream: []const i16, ohwi: []i16) Error!void {
    if (!layout.valid() or ohwi.len != layout.volume()) return error.BadShape;
    var walker = Walker{ .layout = layout, .stream = stream, .ohwi = ohwi };
    try walker.walk();
    if (walker.cursor != stream.len) return error.LongStream;
}

/// How many weights the walk reads, padding included: Vela's padded_length.
pub fn paddedLength(layout: Layout) Error!usize {
    if (!layout.valid()) return error.BadShape;
    var walker = Walker{ .layout = layout };
    try walker.walk();
    return walker.cursor;
}

/// One sub-kernel of one OFM block and one IFM block.
const Brick = struct {
    ofm_z: u32,
    ofm_depth: u32,
    ifm_z: u32,
    ifm_depth: u32,
    y: u32,
    x: u32,
    height: u32,
    width: u32,
};

const Walker = struct {
    layout: Layout,
    stream: ?[]const i16 = null,
    ohwi: []i16 = &.{},
    cursor: usize = 0,

    fn walk(self: *Walker) Error!void {
        const l = self.layout;
        const depthwise = l.traversal == .depthwise;
        const part_kernel = l.traversal == .part_kernel_first;
        const ifm_block: u32 = if (part_kernel or l.ifm_bitdepth == 16) 16 else 32;
        var ofm_z: u32 = 0;
        while (ofm_z < l.ofm_depth) : (ofm_z += l.ofm_block_depth) {
            var ifm_z: u32 = 0;
            while (ifm_z < (if (depthwise) 1 else l.ifm_depth)) : (ifm_z += ifm_block) {
                const ifm_depth = if (depthwise)
                    l.ifm_ublock_depth
                else if (part_kernel)
                    @min(ifm_block, l.ifm_depth - ifm_z)
                else
                    ifm_block;
                var y: u32 = 0;
                while (y < l.kernel_height) : (y += l.decomp_h) {
                    var x: u32 = 0;
                    while (x < l.kernel_width) : (x += l.decomp_w) {
                        try self.brick(.{
                            .ofm_z = ofm_z,
                            .ofm_depth = @min(l.ofm_block_depth, l.ofm_depth - ofm_z),
                            .ifm_z = ifm_z,
                            .ifm_depth = ifm_depth,
                            .y = y,
                            .x = x,
                            .height = @min(l.kernel_height - y, l.decomp_h),
                            .width = @min(l.kernel_width - x, l.decomp_w),
                        });
                    }
                }
            }
        }
    }

    /// Kernel elements are padded to a multiple of 4 (or 2 for 16-bit
    /// part-kernel-first) where the traversal walks them in groups.
    fn elements(self: *const Walker, b: Brick) u32 {
        const n = b.height * b.width;
        return switch (self.layout.traversal) {
            .depth_first => n,
            .depthwise => std.mem.alignForward(u32, n, 4),
            .part_kernel_first => std.mem.alignForward(u32, n, if (self.layout.ifm_bitdepth == 16) 2 else 4),
        };
    }

    fn brick(self: *Walker, b: Brick) Error!void {
        const l = self.layout;
        const part_kernel = l.traversal == .part_kernel_first;
        const outer = if (part_kernel) b.ifm_depth else 1;
        const inner = if (part_kernel) 1 else b.ifm_depth;
        const count = self.elements(b);
        var ifm_outer: u32 = 0;
        while (ifm_outer < outer) : (ifm_outer += l.ifm_ublock_depth) {
            var ofm_ublk: u32 = 0;
            while (ofm_ublk < b.ofm_depth) : (ofm_ublk += l.ofm_ublock_depth) {
                var element: u32 = 0;
                while (element < count) : (element += 1) {
                    var ifm_inner: u32 = 0;
                    while (ifm_inner < inner) : (ifm_inner += l.ifm_ublock_depth) {
                        try self.ublock(b, element, b.ofm_z + ofm_ublk, b.ifm_z + ifm_outer + ifm_inner);
                    }
                }
            }
        }
    }

    fn ublock(self: *Walker, b: Brick, element: u32, ofm_base: u32, ifm_base: u32) Error!void {
        const l = self.layout;
        const kx = element % b.width;
        const ky = element / b.width;
        const ifm_count: u32 = if (l.traversal == .depthwise) 1 else l.ifm_ublock_depth;
        var o: u32 = 0;
        while (o < l.ofm_ublock_depth) : (o += 1) {
            var i: u32 = 0;
            while (i < ifm_count) : (i += 1) {
                const ofm_z = ofm_base + o;
                const ifm_z = ifm_base + i;
                const inside = ifm_z < l.ifm_depth and ofm_z < l.ofm_depth and ky < b.height;
                try self.visit(inside, ofm_z, b.y + ky, b.x + kx, ifm_z);
            }
        }
    }

    fn visit(self: *Walker, inside: bool, ofm_z: u32, wy: u32, wx: u32, ifm_z: u32) Error!void {
        defer self.cursor += 1;
        const stream = self.stream orelse return;
        if (self.cursor >= stream.len) return error.ShortStream;
        if (!inside) return;
        const l = self.layout;
        const index = ((@as(usize, ofm_z) * l.kernel_height + wy) * l.kernel_width + wx) * l.ifm_depth + ifm_z;
        self.ohwi[index] = stream[self.cursor];
    }
};
