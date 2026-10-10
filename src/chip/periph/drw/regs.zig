//! The DRW register map: where each register this model tracks sits in the
//! window, and the field layout read out of one of them.
//!
//! The map lives next to the block rather than inside it, the same way
//! `ulpt/regs.zig` and `eth/regs.zig` sit beside theirs: `drw.zig` carries
//! the meaning (what a write does, what a read answers), and the offsets are
//! a table anyone comparing against the HUM should be able to read on their
//! own.
//!
//! Every DRW register is 32 bits wide (HUM Ch 62.2), so an access narrower
//! than a word names lanes of ONE register, which is the `lanes.zig` shape,
//! not the `bytelanes.zig` shape the RIIC, DTC and ULPT windows need.

/// The window: DRW sits at 0x4044_4000 (HUM Ch 62.1 p 3686).
pub const win_base: u32 = 0x4044_4000;
pub const win_span: u32 = 0x104;

/// Register byte offsets this model tracks (HUM Ch 62.2).
pub const off = struct {
    /// CONTROL on write, STATUS on read.
    pub const control: u32 = 0x000;
    /// CONTROL2 on write, HWREVISION on read.
    pub const control2: u32 = 0x004;
    pub const color1: u32 = 0x064;
    pub const color2: u32 = 0x068;
    pub const size: u32 = 0x078;
    pub const pitch: u32 = 0x07C;
    /// Writing ORIGIN anchors the box and starts the render.
    pub const origin: u32 = 0x080;
    pub const cachectl: u32 = 0x0C4;
    /// Writing DLISTSTART kicks the display-list reader.
    pub const dliststart: u32 = 0x0C8;
};

/// SIZE holds the whole bounding box in one word: the width in the low half,
/// the height in the high one (HUM Ch 62.2.16 p 3700).
pub const field = struct {
    pub const size_mask: u32 = 0xFFFF;
    pub const height_shift: u5 = 16;
};

/// HWREVISION as read from an EK-RA8D2 over J-Link with the domain powered
/// (HUM Ch 62.2.6 p 3696). Reads 0 while the domain is gated, which is the
/// cheapest "is my engine alive" check a driver can make.
pub const hardware_revision: u32 = 0x0FBE_0107;
