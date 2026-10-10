//! MRMAC0/MRMAC1: the address the RMAC matches a frame against, and the port
//! mode a store has to land in to reach it.
//!
//! The perfect-match address is two words of the RMAC window: MRMAC0 (+0x84)
//! carries the top two octets in its MAU field and MRMAC1 (+0x88) the bottom
//! four, which is the layout `ra8_rmac_set_mac_address` builds
//! (ra8_rmac.c:582, citing HUM Ch 33.4 "MRMAC0/MRMAC1 : MAC Reception MAC
//! Address Configuration Registers" p 1707, with the per-register pages at
//! p 1716 and p 1717).
//!
//! THE PAIR IS NOT PLAIN STORAGE. It sits behind the same gate as MPIC: a
//! store only sticks while the ETHA port paired with this RMAC is in CONFIG,
//! and a store made while the port is running is swallowed. `ra8_eth.c:441`
//! says so from the bench rather than from the manual: "without the DISABLE
//! -> CONFIG -> {MAC write} -> DISABLE -> OPERATION bracket, MRMAC0 / MRMAC1
//! read back as 0 after ra8_eth_open completes, and every wire-side ARP
//! who-has gets dropped at the RMAC perfect-match comparator before the GWCA
//! descriptor ring ever sees it". That is the failure this model could not
//! reproduce: the two words were not claimed by any block, so the bus kept
//! whatever was written to them at any mode, and a driver that programmed its
//! address with the port already operational read the address back here and
//! answered nothing on the wire. The store is refused and counted now, the
//! same cut the gateway's ring-base registers already take against a GWCA in
//! CONFIG.
//!
//! NOT MODELLED, AND NOT GUESSED: the comparator itself. Nothing in this tree
//! receives a frame addressed to the port, so the address is carried and
//! reported, never matched against anything. The bits above MAU are left as
//! written rather than read back as zero: ra8_rmac_regs.h names the field's
//! extent, not what silicon does with the rest of the word.
const lanes = @import("../lanes.zig");
const eth_mode = @import("mode.zig");

/// Where the pair sits inside the RMAC window (ra8_rmac_regs.h:175).
pub const off = struct {
    pub const mrmac0: u32 = 0x0084;
    pub const mrmac1: u32 = 0x0088;
    /// The two words together, which is the window this block claims.
    pub const span: u32 = 0x0008;
};

pub const field = struct {
    /// MRMAC0.MAU, the top two octets (k_ra8_rmac_mask_mrmac0_mau).
    pub const mau: u32 = 0x0000_FFFF;
};

/// An IEEE 802 address is six octets.
pub const octet_count: usize = 6;

/// Whether a store to the pair reaches the registers at all. CONFIG only:
/// RESET and DISABLE have not brought the port far enough and OPERATION is
/// the case the bench note is about.
pub fn takes(mode: eth_mode.Mode) bool {
    return mode == .config;
}

/// The register pair, and what a run did to it.
pub const Address = struct {
    mrmac0: u32 = 0,
    mrmac1: u32 = 0,
    /// Stores that landed, so the address the port answers to changed.
    stores: u32 = 0,
    /// Stores swallowed because the port was not in CONFIG.
    ignored: u32 = 0,

    pub fn quiet(self: *const Address) bool {
        return self.stores == 0 and self.ignored == 0;
    }

    /// Whether anything was ever programmed, so a port that only ever had
    /// the address refused still says so in the report.
    pub fn programmed(self: *const Address) bool {
        return self.mrmac0 & field.mau != 0 or self.mrmac1 != 0;
    }

    pub fn read(self: *const Address, offset: u32, width: u3) u32 {
        const whole: u32 = switch (lanes.word(offset)) {
            off.mrmac0 => self.mrmac0,
            off.mrmac1 => self.mrmac1,
            else => 0,
        };
        return lanes.part(whole, lanes.lane(offset), width);
    }

    /// A store. Narrow is fine on either word, so a driver that builds the
    /// address in halfwords still gets there; what decides the store is the
    /// port's mode, not its width.
    pub fn write(self: *Address, mode: eth_mode.Mode, offset: u32, width: u3, value: u32) void {
        const held = switch (lanes.word(offset)) {
            off.mrmac0 => &self.mrmac0,
            off.mrmac1 => &self.mrmac1,
            else => return,
        };
        if (!takes(mode)) {
            self.ignored +%= 1;
            return;
        }
        held.* = lanes.merge(held.*, lanes.lane(offset), width, value);
        self.stores +%= 1;
    }

    /// The six octets in wire order, MAU's high byte first (ra8_rmac.c:594).
    pub fn octets(self: *const Address) [octet_count]u8 {
        return .{
            @truncate(self.mrmac0 >> 8),
            @truncate(self.mrmac0),
            @truncate(self.mrmac1 >> 24),
            @truncate(self.mrmac1 >> 16),
            @truncate(self.mrmac1 >> 8),
            @truncate(self.mrmac1),
        };
    }
};
