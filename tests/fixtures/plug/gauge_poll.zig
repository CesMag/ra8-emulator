//! RA8EMU-212 fixture: firmware that keeps polling the MAX17048 fuel gauge
//! at 0x36 on RIIC channel 1, the board's sensor line, and counts what the
//! bus answers. The test unplugs and replugs the gauge mid-run and reads the
//! counts back to see the firmware notice both.
//!
//! Words at SRAM 0x22000100: polls, acks, nacks, and changes (how many times
//! the answer flipped between ack and nack).

const riic: u32 = 0x4025_E100;
const iccr1: u32 = 0x00;
const iccr2: u32 = 0x01;
const icsr2: u32 = 0x09;
const icdrt: u32 = 0x12;

/// MSTPCRB: channel 1 runs once bit 8 is clear (HUM 11.2.7).
const mstpcrb: *volatile u32 = @ptrFromInt(0x4020_3004);
const riic1_stop: u32 = 1 << 8;

const gauge: u8 = 0x36;
const out: *volatile [4]u32 = @ptrFromInt(0x2200_0100);

const Vectors = extern struct {
    sp: u32,
    reset: *const fn () callconv(.c) noreturn,
};

export const vector_table linksection(".isr_vector") = Vectors{
    .sp = 0x2219_FFF8,
    .reset = &Reset_Handler,
};

fn reg(offset: u32) *volatile u8 {
    return @ptrFromInt(riic + offset);
}

fn waitSet(offset: u32, bit: u8) void {
    while (reg(offset).* & bit == 0) {}
}

/// One address-only write to the gauge: START, address, STOP. True when
/// nothing acknowledged it.
fn probe() bool {
    while (reg(iccr2).* & 0x80 != 0) {}
    reg(iccr2).* = 0x02;
    waitSet(icsr2, 0x80);
    reg(icdrt).* = gauge << 1;
    waitSet(icsr2, 0x40);
    const nacked = reg(icsr2).* & 0x10 != 0;
    reg(iccr2).* = 0x08;
    waitSet(icsr2, 0x08);
    reg(icsr2).* = 0;
    return nacked;
}

export fn Reset_Handler() callconv(.c) noreturn {
    out.* = .{ 0, 0, 0, 0 };
    mstpcrb.* &= ~riic1_stop;
    reg(iccr1).* = 0xC0;
    reg(iccr1).* = 0x80;
    var last = false;
    while (true) {
        const nacked = probe();
        if (nacked) out[2] +%= 1 else out[1] +%= 1;
        if (out[0] != 0 and nacked != last) out[3] +%= 1;
        last = nacked;
        out[0] +%= 1;
    }
}
