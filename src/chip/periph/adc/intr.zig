//! ADINTCR: the scan-end interrupt enable, which is why a scan that ran can
//! still owe the core nothing.
//!
//! ADINTCR sits at +0x005C in the ADC_B window (ra8_adc_b_regs.h
//! `k_ra8_adc_b_off_adintcr`, HUM Ch 53.2.2.6 "Scan End Interrupt Enable
//! Register" p 3327). A scan-end event only reaches the ICU when this
//! register says the interrupt is enabled; with it clear the conversion
//! still happens, the results still land, and nothing is raised.
//!
//! That is not a corner: the in-tree driver writes ADINTCR = 0 in
//! `ra8_adc_init`, again in `ra8_adc_init_configured`, and again in
//! `ra8_adc_deinit` (libs/ra8_hal/src/adc.c), so every polling image the HAL
//! brings up runs with scan-end interrupts off. A model that raises the
//! event anyway hands those images an interrupt silicon never gives them,
//! and an image that links the event and polls IELSR.IR sees a flag latch
//! that a bench run leaves clear.
//!
//! NOT MODELLED, AND NOT GUESSED: which bit is which group. Neither tree
//! carries a bit table for this register. Its siblings across the block name
//! theirs (ADSGER SGREn[8:0], ADTRGENR STTRGENn[8:0], ADSYSTR ADSYSTn[8:0]),
//! ADINTCR does not, and a per-group bit inferred from the neighbours would
//! be an invention about silicon rather than a reading of it. So the one
//! thing the register is read for here is the one thing that holds whatever
//! the layout turns out to be: all-zero enables no group, and anything else
//! is taken as enabled. A later slice with the table in hand narrows it to
//! the group that scanned.
/// Where the register lives inside the ADC_B window.
pub const off_adintcr: u32 = 0x005C;

/// Whether a scan-end event may be raised at all. Zero enables no group, on
/// any reading of the bit order.
pub fn enabled(adintcr: u32) bool {
    return adintcr != 0;
}
