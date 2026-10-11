//! How the FP instruction groups name and reach the S/D bank. A register
//! field is a 4-bit V plus one extra bit X: single precision numbers it
//! V:X (S0-S31), double precision X:V, which on M-profile only reaches
//! D0-D15, so a double with X set names a register that does not exist.
//! Half precision uses the single numbering: it reads S[i]<15:0> and
//! writes Zeros(16):value.
const fpu = @import("../../fpu/all.zig");
const Format = fpu.format.Format;
const Bank = fpu.bank.Bank;

/// The register a V:X field pair names.
pub fn index(v: u4, x: u1, double: bool) u5 {
    const wide_v: u5 = v;
    const wide_x: u5 = x;
    return if (double) wide_x << 4 | wide_v else wide_v << 1 | wide_x;
}

/// False for a double register M-profile does not have (D16+).
pub fn exists(i: u5, double: bool) bool {
    return !double or i < 16;
}

pub fn read(comptime fmt: Format, bank: *const Bank, i: u5) fmt.Bits() {
    if (comptime fmt.width() == 64) return bank.readD(@intCast(i & 0xF));
    if (comptime fmt.width() == 16) return @truncate(bank.readS(i));
    return bank.readS(i);
}

pub fn write(comptime fmt: Format, bank: *Bank, i: u5, value: fmt.Bits()) void {
    if (comptime fmt.width() == 64) return bank.writeD(@intCast(i & 0xF), value);
    bank.writeS(i, value);
}
