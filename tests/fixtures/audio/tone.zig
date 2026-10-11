//! RA8EMU-650 tone fixture: a freestanding Cortex-M85 image that brings
//! SSIE0 up the way ra8_ssie.c does and transmits a 1 kHz square wave.
//!
//! First it cancels SSIE0's module stop (MSTPCRC bit 8, HUM 11.2.8), as the
//! FSP's R_BSP_MODULE_START does; every module but SRAM resets stopped.
//! Handshake: wait for SSISR.IIRQ (neither direction enabled), program the
//! stream shape in SSICR, then set TEN. Shape: DWL 001b (16-bit data),
//! FRM 00b (two words a frame, so left then right), PDTA 1 (right
//! justified). Each frame carries the same level on both channels: 24
//! frames at +0x4000 then 24 at -0x4000 is one period, 48 frames, which is
//! 1 kHz at a 48 kHz audio rate. Ten periods, then the done marker.
const mstpcrc: *volatile u32 = @ptrFromInt(0x4020_3008);
const mstp_ssie0: u32 = 1 << 8;
const ssie0: usize = 0x4025_D000;
const ssicr: *volatile u32 = @ptrFromInt(ssie0 + 0x00);
const ssisr: *volatile u32 = @ptrFromInt(ssie0 + 0x04);
const ssiftdr: *volatile u32 = @ptrFromInt(ssie0 + 0x18);
const done: *volatile u32 = @ptrFromInt(0x2200_0100);

const iirq: u32 = 0x0200_0000;
const ten: u32 = 0x0000_0002;
const dwl_16: u32 = 1 << 19;
const pdta: u32 = 1 << 9;

pub const frames_per_period: u32 = 48;
pub const periods: u32 = 10;
const high: u32 = 0x4000;
const low: u32 = 0xC000;
const done_marker: u32 = 0x70E0_C0DE;

const Vectors = extern struct {
    stack: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vectors linksection(".isr_vector") = Vectors{ .stack = 0x2219_FFF8, .reset = &reset };

fn reset() callconv(.c) noreturn {
    mstpcrc.* &= ~mstp_ssie0;
    while (ssisr.* & iirq == 0) {}
    ssicr.* = dwl_16 | pdta;
    ssicr.* = dwl_16 | pdta | ten;
    var frame: u32 = 0;
    while (frame < frames_per_period * periods) : (frame += 1) {
        const level = if (frame % frames_per_period < frames_per_period / 2) high else low;
        ssiftdr.* = level;
        ssiftdr.* = level;
    }
    done.* = done_marker;
    while (true) {}
}
