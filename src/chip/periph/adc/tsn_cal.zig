//! The temperature sensor's factory calibration words, as memory.
//!
//! HUM Ch 55.2.2 p 3498-3499 puts TSCDR and TSCDR2 in the MRAM trim area at
//! 0x02C1_EDA0: TSCDR is the ADC code the die read at the high reference
//! (125 degC on the EK-RA8D2's part) and TSCDR2 the code at -40 degC. Only
//! the low 12 bits carry the code. The firmware's TSN driver reads both
//! with ordinary loads and converts a live sample with a two-point line.
//!
//! Nothing mapped that page, so adc_diag_tsn_demo stopped in
//! ra8_tsn_convert_to_milli_c on an unmapped read of 0x02C1_EDA0.
//!
//! The words seeded here pair with adc_scan.temperature_code (1800): the
//! firmware's integer maths turns that code into 26.000 degC, the same
//! plausible deterministic die the ADC model already promised. A page an
//! image already mapped keeps its bytes, the way mram/window.zig does.
const Guest = @import("../../core/cpu/memory/guest/guest.zig");

pub const page: u32 = 0x1000;

/// Where the two words live.
pub const addr = struct {
    pub const tscdr: u32 = 0x02C1_EDA0;
    pub const tscdr2: u32 = 0x02C1_EDA4;
    pub const page_base: u32 = tscdr & ~(page - 1);
};

/// The seeded codes: high reference (125 degC) and low reference (-40 degC).
pub const code = struct {
    pub const high: u32 = 2790;
    pub const low: u32 = 1140;
};

/// Map the page and seed both words. Returns false and writes nothing when
/// something already mapped the page.
pub fn map(machine: Guest.Guest) Guest.Error!bool {
    machine.map(addr.page_base, page) catch return false;
    try machine.writeWord(addr.tscdr, code.high);
    try machine.writeWord(addr.tscdr2, code.low);
    return true;
}
