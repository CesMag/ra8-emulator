//! DOTF conversion area: which XSPI addresses a channel decrypts over.
//!
//! CONVAREAST and CONVAREAD do not hold a byte address. The bottom twelve
//! bits are reserved and the hardware scales the stored value by 4 KB, so a
//! region is 4 KB aligned and 4 KB granular (ra8_dotf_regs.h, HUM Ch 45.3.1
//! and 45.3.2 p 3049). The two registers also read back differently: the
//! start register's reserved field reads as zero, the end register's reads
//! as one, which the header quotes from the HUM outright ("These bits are
//! read as 1"). A driver that reads CONVAREAD back and compares it against
//! what it wrote is reading a value the hardware changed under it.
//!
//! Each channel is also bound to one XSPI window and decrypts nothing
//! outside it: DOTF0 over XSPI0 at 0x8000_0000..0x9FFF_FFFF, DOTF1 over
//! XSPI1 at 0x7000_0000..0x7FFF_FFFF (ra8_dotf_regs.h
//! ra8_dotf_xspi_window_t, HUM Ch 45.3 p 3049).
//!
//! TWO THINGS THE PAIR CAN BE ASKED FOR THAT SILICON DOES NOT ALLOW, and
//! both were silent here. The HUM records each as a requirement on the
//! driver without saying what the hardware does when it is broken, so
//! neither is refused: the store lands and the run says so, the same cut
//! src/chip/periph/pfs/route.zig makes for a prohibited pin handover.
//!
//! A REVERSED PAIR. "Setting CONVAREAST[31:12] > CONVAREAED[31:12] is
//! prohibited" (HUM Ch 45.3.1 p 3049, quoted in ra8_dotf.c
//! internal_validate_region, which returns invalid-arg for it). It is why
//! FSP writes the two registers END FIRST: r_ospi_b.c says "Set the end and
//! start area for DOTF conversion in that order to ensure that end address
//! is always higher than start address", and ra8_dotf_select_region follows
//! it. Programming start first and end second passes through start > end = 0
//! on the way, which is the ordinary sequence and not the prohibited state,
//! so a pair whose END is still at its reset value names nothing to count.
//!
//! A LIVE AREA CHANGE. ra8_dotf_select_region carries the precondition
//! "Channel is currently disabled (HUM 45.3.1 p 3049)" and expects the
//! caller to have run ra8_dotf_disable first. Moving the conversion area
//! underneath a running AES core hands the decrypting path a region the
//! firmware has half-replaced, and an image that does it reads plaintext
//! for one region and ciphertext for the other with nothing to say which.

/// The 4 KB granule the address registers are scaled in.
pub const granule: u32 = 0x0000_1000;

/// CONVAREAST / CONVAREAD field split: the high twenty bits carry the value.
pub const field = struct {
    pub const address: u32 = 0xFFFF_F000;
    pub const reserved: u32 = 0x0000_0FFF;
};

/// What the reserved field of each register reads back as.
pub const reserved_reads = struct {
    pub const start: u32 = 0x0000_0000;
    pub const end: u32 = field.reserved;
};

/// One channel's XSPI window: the only addresses it can be asked to cover.
pub const Window = struct {
    lo: u32,
    hi: u32,

    pub fn holds(self: Window, target: u32) bool {
        return target >= self.lo and target <= self.hi;
    }
};

/// The window bound to a channel. A channel index this part does not have
/// covers nothing.
pub fn window(channel: usize) Window {
    return switch (channel) {
        0 => .{ .lo = 0x8000_0000, .hi = 0x9FFF_FFFF },
        1 => .{ .lo = 0x7000_0000, .hi = 0x7FFF_FFFF },
        else => .{ .lo = 0, .hi = 0 },
    };
}

/// The byte address a stored register value names.
pub fn address(stored: u32) u32 {
    return stored & field.address;
}

/// CONVAREAST as firmware reads it back.
pub fn startReadback(stored: u32) u32 {
    return address(stored) | reserved_reads.start;
}

/// CONVAREAD as firmware reads it back, reserved bits standing at one.
pub fn endReadback(stored: u32) u32 {
    return address(stored) | reserved_reads.end;
}

/// True when the pair names a region at all. An end below its start covers
/// nothing, which is how an unprogrammed channel reads.
pub fn programmed(start: u32, end: u32) bool {
    return address(end) >= address(start) and address(end) != 0;
}

/// True when the programmed region covers this address. The end register
/// names the last 4 KB page, so the region runs to the top of that page.
pub fn covers(start: u32, end: u32, target: u32) bool {
    if (!programmed(start, end)) return false;
    return target >= address(start) and target <= address(end) +| (granule - 1);
}

/// How many 4 KB pages the region spans.
pub fn pages(start: u32, end: u32) u32 {
    if (!programmed(start, end)) return 0;
    return ((address(end) - address(start)) / granule) + 1;
}

/// True when the pair names a region this window does not wholly hold. The
/// end register names the last 4 KB page, so the region runs to the top of
/// that page and both edges have to sit inside the window.
///
/// A pair with either register still at its reset value names no region to
/// refuse. Both registers reset to zero, a driver programs them one at a
/// time and sometimes end first (fw/real/dotf.c does), and zero is inside
/// neither channel's XSPI window, so judging the pair while one half of it
/// is still zero refuses a channel part-way through a legal sequence. The
/// cost of that rule is a genuine region anchored at address zero, which
/// this cannot tell apart from an unprogrammed start and so never refuses.
pub fn outsideWindow(bound: Window, start: u32, end: u32) bool {
    if (address(start) == 0 or !programmed(start, end)) return false;
    return !bound.holds(address(start)) or !bound.holds(address(end) +| (granule - 1));
}

/// True when the pair is the prohibited one: a start above its end
/// (HUM Ch 45.3.1 p 3049). A pair whose end is still at its reset value is
/// a driver part-way through programming start-then-end, not a reversed
/// region, so it is not counted; the cost is a genuine region ending at
/// address zero, which cannot be told apart from an unprogrammed end and
/// which no XSPI window holds anyway.
pub fn reversed(start: u32, end: u32) bool {
    if (address(end) == 0) return false;
    return address(start) > address(end);
}
