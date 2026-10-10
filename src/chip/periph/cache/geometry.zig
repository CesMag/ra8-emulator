//! The cache geometry registers: what CTR and CCSIDR say the L1 caches are.
//!
//! These are Arm v8-M architectural registers in the PPB, not RA8D2
//! peripherals, so the references here are the Arm v8-M ARM rather than the
//! Hardware User's Manual. The PPB is plain RAM in this tree, and RAM starts
//! at zero, so both of these read as zero until something primes them. Zero
//! is not a harmless default for either:
//!
//!   CTR.DminLine[19:16] is the log2 of the smallest D-cache line in WORDS,
//!   and `ra8_cache_dcache_line_bytes` returns `4 << DminLine`. A zero field
//!   answers four bytes. Every by-address maintenance call then walks the
//!   range in four-byte steps: `ra8_cache_dcache_clean_by_addr` over a 4 KiB
//!   buffer writes DCCMVAC 1024 times instead of 128. The same number is what
//!   `ra8_spi_b_dma.c` rounds its DMA buffers up to, so a wrong line size
//!   also mis-sizes the cache-aligned staging it computes.
//!
//!   CCSIDR is the set/way geometry the whole-cache walk reads. The driver
//!   guards it: `internal_ra8_cache_setway_all` returns without writing
//!   anything when CCSIDR is all-zero or all-ones, calling that geometry
//!   unavailable.
//!
//! The line size is grounded: `ra8_cache.h` says outright that on the RA8D2's
//! Cortex-M85 CTR.DminLine reports 32 bytes. The set/way geometry is NOT: the
//! number of sets and ways of this part's L1 D-cache is in neither tree, and
//! inventing one would make the walk write a made-up number of maintenance
//! stores. So CCSIDR keeps the value the driver already reads as unavailable,
//! and the walk keeps declining, on purpose and in the open.

/// Bytes in the 32-bit word CTR counts a line in.
pub const word_bytes: u32 = 4;

/// CTR: the cache line sizes, as log2 word counts.
pub const ctr = struct {
    /// DminLine[19:16]: smallest D-cache line, log2 words.
    pub const dmin_shift: u5 = 16;
    pub const dmin_mask: u32 = 0xF;
    /// IminLine[3:0]: smallest I-cache line, log2 words.
    pub const imin_shift: u5 = 0;
    pub const imin_mask: u32 = 0xF;
};

/// CCSIDR: the set/way geometry of whichever cache CSSELR selected.
pub const ccsidr = struct {
    /// NumSets[27:13], held as sets minus one.
    pub const sets_shift: u5 = 13;
    pub const sets_mask: u32 = 0x7FFF;
    /// Associativity[12:3], held as ways minus one.
    pub const assoc_shift: u5 = 3;
    pub const assoc_mask: u32 = 0x3FF;
    /// LineSize[2:0], log2 of the line in words, minus two.
    pub const line_shift: u5 = 0;
    pub const line_mask: u32 = 0x7;
    /// What the driver treats as no geometry at all, both spellings of it.
    pub const unavailable: u32 = 0;
    pub const unavailable_ones: u32 = 0xFFFF_FFFF;
};

/// CCR: the two cache enables the driver read-modify-writes.
pub const ccr = struct {
    /// DC[16]: L1 data cache enable.
    pub const dcache: u32 = 1 << 16;
    /// IC[17]: L1 instruction cache enable.
    pub const icache: u32 = 1 << 17;
    pub const both: u32 = dcache | icache;
};

/// The RA8D2's Cortex-M85 D-cache line, in bytes. `ra8_cache.h`:
/// "On the RA8D2's Cortex-M85 this is 32 bytes."
pub const dcache_line_bytes: u32 = 32;

/// Line size in bytes from a CTR value, the same arithmetic the driver does.
pub fn lineBytes(value: u32) u32 {
    return word_bytes << @intCast((value >> ctr.dmin_shift) & ctr.dmin_mask);
}

/// The DminLine field that reports a line of `bytes`. The inverse of
/// `lineBytes`, used to build the CTR this part should read as.
pub fn dminFor(bytes: u32) u32 {
    var words = bytes / word_bytes;
    var field: u32 = 0;
    while (words > 1) : (words >>= 1) field += 1;
    return field & ctr.dmin_mask;
}

/// What CTR reads as here: the grounded D-cache line, and the same value for
/// the I-cache line because the two are one line size on this core. Every
/// other CTR field reads zero, because nothing in either tree names them and
/// nothing in the driver reads them.
pub fn reportedCtr() u32 {
    const field = dminFor(dcache_line_bytes);
    return (field << ctr.dmin_shift) | (field << ctr.imin_shift);
}

/// Whether the driver's own guard would call this geometry unavailable and
/// walk nothing.
pub fn unavailable(value: u32) bool {
    return value == ccsidr.unavailable or value == ccsidr.unavailable_ones;
}

/// Sets in the selected cache. CCSIDR holds them minus one.
pub fn sets(value: u32) u32 {
    return ((value >> ccsidr.sets_shift) & ccsidr.sets_mask) + 1;
}

/// Ways in the selected cache. CCSIDR holds them minus one.
pub fn ways(value: u32) u32 {
    return ((value >> ccsidr.assoc_shift) & ccsidr.assoc_mask) + 1;
}

/// How many set/way stores a whole-cache walk of this geometry would make.
/// Zero when the guard declines it.
pub fn setWayStores(value: u32) u64 {
    if (unavailable(value)) return 0;
    return @as(u64, sets(value)) * @as(u64, ways(value));
}

/// Maintenance stores a by-address operation makes over `size` bytes from
/// `at`, at the line size `value` reports: the count the driver's own span
/// arithmetic arrives at.
pub fn rangeStores(value: u32, at: u32, size: u32) u32 {
    if (size == 0) return 0;
    const line = lineBytes(value);
    const mask = line - 1;
    const start = at & ~mask;
    const last = (at +% size - 1) & ~mask;
    return ((last - start) / line) + 1;
}
