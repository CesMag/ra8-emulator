//! The framebuffer descriptor a graphics layer's registers describe, and
//! the RAM it is allowed to live in.
//!
//! Split out of glcdc.zig, which is about the register window: this is about
//! the thing the window describes, and since the decode below is the only
//! reader of the FLM field positions, they live here beside it rather than
//! in the window's own offset table. A descriptor whose BASE is outside every
//! RAM window a bus initiator can reach is not a framebuffer however well
//! formed the rest of it reads, and a descriptor whose last line runs past
//! the end of the window it started in is the failure the scan refuses on.
const memmap = @import("../../core/memmap.zig");
const pixel = @import("pixel.zig");
const scan = @import("scan.zig");

/// A RAM window a framebuffer may legally live in on this board.
pub const Window = memmap.Window;

/// The controller fetches over the fabric like any other bus initiator, so the
/// RAM it may be pointed at is `memmap.initiator_ram` and nothing else: the
/// on-chip SRAM and the external SDRAM through both of its aliases.
///
/// This used to be a private table of its own, and it disagreed with the
/// address space in two ways that both showed up as the panel going dark
/// for the wrong reason. It ran the SRAM window to 0x2220_0000, a megabyte
/// past where the SRAM actually ends, so a framebuffer over that edge was
/// accepted and then refused a second time as unreadable memory. And it did
/// not carry the Non-secure SDRAM alias at all, so a framebuffer at
/// 0x7800_0000, which the loader maps as RAM like any other, was not a
/// framebuffer here however well formed the descriptor was.
pub const ram_windows = memmap.initiator_ram;

/// Sanity cap on a decoded dimension, so a half-programmed layer does not
/// read back as a plausible 60000-pixel-wide panel.
pub const max_dimension: u32 = 4096;

/// The FLM field positions a descriptor is decoded from (HUM Ch 63).
pub const field = struct {
    /// FLMRD.RENB, bit 0: this layer fetches from its framebuffer.
    pub const renb: u32 = 0x1;
    pub const stride_shift: u5 = 16;
    pub const stride_mask: u32 = 0xFFFF;
    pub const lnnum_shift: u5 = 16;
    pub const lnnum_mask: u32 = 0x7FF;
    pub const format_shift: u5 = 28;
    pub const format_mask: u32 = 0x7;
};

/// The five layer registers a descriptor is built out of, already read from
/// the window so this file needs nothing of the bus.
pub const Registers = struct {
    flmrd: u32,
    flm2: u32,
    flm3: u32,
    flm5: u32,
    flm6: u32,
};

/// Recover one layer's descriptor. Width comes back from the stride and the
/// format's fetch width, height from LNNUM + 1. A layer that is not
/// fetching, or whose base is not in RAM, or whose geometry is not sane, is
/// not a framebuffer and is reported as none rather than as zeroes.
pub fn decode(regs: Registers, layer: u8, enabled: bool) ?Framebuffer {
    if (regs.flmrd & field.renb == 0) return null;
    if (!addressIsRam(regs.flm2)) return null;
    const stride = regs.flm3 >> field.stride_shift & field.stride_mask;
    const lines = (regs.flm5 >> field.lnnum_shift & field.lnnum_mask) + 1;
    const format: pixel.Format = @fromBackingInt(@intCast(regs.flm6 >> field.format_shift & field.format_mask));
    if (stride == 0) return null;
    // Bits, not bytes: a CLUT4 line of `stride` bytes carries twice as many
    // pixels as it has bytes, and a CLUT1 line eight times as many. dev
    // divides by a bytes-per-pixel that rounds both up to one, so every
    // sub-byte layer it has ever reported came out too narrow.
    const width = format.pixelsIn(stride);
    if (width == 0 or width > max_dimension or lines > max_dimension) return null;
    return .{
        .base = regs.flm2,
        .width = width,
        .height = lines,
        .stride = stride,
        .format = format,
        .layer = layer,
        .enabled = enabled,
    };
}

/// What the panel is being scanned from, recovered from one layer's
/// registers.
pub const Framebuffer = struct {
    base: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: pixel.Format,
    /// 1 or 2: which graphics layer is fetching.
    layer: u8,
    /// Whether the output stage (BG_EN.EN) is on behind it.
    enabled: bool,
};

/// The scan's view of a descriptor: the same framebuffer, said in the terms
/// the scanner works in (bits per pixel, the decoder, where the RAM window
/// the base sits in ends).
pub fn shapeOf(frame: Framebuffer) scan.Shape {
    return .{
        .base = frame.base,
        .width = frame.width,
        .height = frame.height,
        .stride = frame.stride,
        .bits = frame.format.bits(),
        .decode = frame.format.decoder(),
        .indexed = frame.format.indexed(),
        .window_end = windowEnd(frame.base),
    };
}

/// Where the RAM window an address sits in ends, or null when it sits in
/// none. The descriptor decode only asks whether the BASE is in RAM; a
/// framebuffer whose base is fine and whose last line is past the end of
/// the window is the failure this answers.
pub fn windowEnd(address: u32) ?u32 {
    const window = memmap.initiatorWindow(address) orelse return null;
    return window.end;
}

/// Whether an address points into a RAM window a framebuffer can live in.
pub fn addressIsRam(address: u32) bool {
    return memmap.initiatorWindow(address) != null;
}
