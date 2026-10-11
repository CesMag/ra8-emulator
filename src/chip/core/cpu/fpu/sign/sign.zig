//! FPNeg and FPAbs from the Arm ARM (DDI0553): the sign bit flipped or
//! cleared, everything else untouched. Neither processes NaNs nor raises a
//! floating-point exception, so a signalling NaN keeps its payload and FPSCR
//! is not read or written. VNEG and VABS in every precision are these.

pub fn neg32(op: u32) u32 {
    return op ^ sign.single;
}

pub fn abs32(op: u32) u32 {
    return op & ~sign.single;
}

pub fn neg64(op: u64) u64 {
    return op ^ sign.double;
}

pub fn abs64(op: u64) u64 {
    return op & ~sign.double;
}

pub const sign = struct {
    pub const single: u32 = 0x8000_0000;
    pub const double: u64 = 0x8000_0000_0000_0000;
};
