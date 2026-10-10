//! The Armv8-M Security Attribution Unit register window.
//!
//! This block exists because of ONE READ. The secure boot's SAU bring-up
//! opens with `SAU_TYPE & 0xFF` and programmes nothing at all unless the
//! count it finds there is bigger than the number of regions its boot map
//! needs. The PPB is mapped as ordinary RAM, so that read gave back zero,
//! the check failed, and ra8_tz_secure_boot_sau_init returned 0x107 without
//! writing a single region. Everything downstream of it in the secure boot
//! (the security init, the CPU1 release, the BLXNS into the Non-Secure
//! image) hangs off that return, so a run of cpu1_pingpong_ipc parked in the
//! Secure fallback main() forever and reported nothing about TrustZone at
//! all. TYPE is hardwired on silicon; nothing the firmware does would ever
//! have put the count there, so the model has to.
//!
//! RBAR/RLAR ARE BANKED THROUGH RNR, the same shape src/chip/periph/mpu/mpu.zig
//! already carries for the MPU window beside this one. Five regions get
//! programmed as five RNR/RBAR/RLAR triples, and with the PPB as plain RAM
//! each triple would overwrite the last and the table would read back
//! holding only the fifth. The block keeps its own table, filed under the
//! region RNR names at the moment of the store.
//!
//! ATTRIBUTION IS NOT ENFORCED HERE and that is deliberate, said plainly so
//! a later slice does not mistake the gap for an oversight. This model runs
//! one flat, fully-accessible address space; it has no Secure and
//! Non-Secure worlds to place an access in. What the block does is answer
//! the capability read honestly and keep the map the firmware programmed, so
//! the report can say what the firmware asked for. Refusing accesses by it
//! is a separate piece of work and needs the world split first.
const memmap = @import("../core/memmap.zig");

/// What the programmed map says about an address. src/chip/periph/sau_attr.zig.
pub const attribution = @import("sau_attr.zig");
/// The RA8 IDAU map that feeds the attribution. src/chip/periph/idau.zig.
pub const idau = @import("idau.zig");

/// The window's fixed shape: how many regions this core reports out of TYPE.
pub const geometry = struct {
    /// Regions the modelled core implements. dev's emu_console.h seeds
    /// SAU_TYPE with 0x0000_0008 and calls it "SAU_TYPE.SREGION: M85
    /// implements 8", which is the count the C emulator has been handing
    /// this same firmware all along.
    pub const regions: u8 = 8;
    /// What a read of TYPE gives back: SREGION sits in the low byte and the
    /// rest of the word is reserved.
    pub const type_value: u32 = regions;

    /// The region a select value names, wrapped into the implemented set the
    /// way a 3-bit RNR field does with 8 regions.
    pub fn selects(rnr: u32) u8 {
        return @intCast(rnr % regions);
    }
};

pub const field = struct {
    /// CTRL[0] ENABLE, [1] ALLNS: whether memory outside every region is
    /// treated as Non-Secure.
    pub const ctrl_enable: u32 = 1 << 0;
    pub const ctrl_allns: u32 = 1 << 1;
    /// TYPE.SREGION, the implemented region count.
    pub const sregion: u32 = 0x0000_00FF;
    /// RLAR[0] ENABLE, [1] NSC: the region is Non-Secure Callable rather
    /// than plain Non-Secure.
    pub const rlar_enable: u32 = 1 << 0;
    pub const rlar_nsc: u32 = 1 << 1;
    /// BADDR and LADDR hold [31:5]: regions are aligned and sized in 32
    /// bytes, as in the MPU window.
    pub const address: u32 = 0xFFFF_FFE0;
    /// A LIMIT is inclusive, so the low five bits the field cannot hold read
    /// as ones rather than zeros.
    pub const limit_low: u32 = 0x1F;
};

/// One region as the firmware left it: the inclusive span it covers and what
/// it says about that span's security attribution.
pub const Region = struct {
    base: u32 = 0,
    limit: u32 = 0,
    /// RLAR.NSC. A Non-Secure Callable region is the narrow door Secure code
    /// leaves open for Non-Secure callers, so it is worth telling apart from
    /// a plainly Non-Secure one in the report.
    callable: bool = false,
    enabled: bool = false,
    /// The two words exactly as the firmware wrote them, kept whole so
    /// putting a region back in front of the firmware after an RNR change
    /// returns what it programmed, reserved bits and all.
    rbar: u32 = 0,
    rlar: u32 = 0,

    /// Read one region out of the RBAR/RLAR pair that programs it.
    pub fn fromPair(rbar: u32, rlar: u32) Region {
        return .{
            .base = rbar & field.address,
            .limit = (rlar & field.address) | field.limit_low,
            .callable = rlar & field.rlar_nsc != 0,
            .enabled = rlar & field.rlar_enable != 0,
            .rbar = rbar,
            .rlar = rlar,
        };
    }

    /// Whether an address falls inside this region, span only: an entry that
    /// is not enabled covers nothing.
    pub fn covers(self: Region, at: u32) bool {
        return self.enabled and at >= self.base and at <= self.limit;
    }

    pub fn bytes(self: Region) u32 {
        if (!self.enabled or self.limit < self.base) return 0;
        return self.limit - self.base + 1;
    }
};

/// The SAU window: the hardwired count the firmware reads out of it, and the
/// region map it programmes into it.
pub const Sau = struct {
    table: [geometry.regions]Region = @splat(.{}),
    /// RNR as the firmware last left it.
    selected: u8 = 0,
    /// CTRL as the firmware last left it, so the report can say whether the
    /// firmware finished by switching attribution on.
    ctrl: u32 = 0,
    /// Stores to TYPE turned away, the read-only rule this block enforces.
    refused: u32 = 0,
    /// Stores into a banked RBAR or RLAR, so a run that programmed the map
    /// is distinguishable from one that read TYPE and gave up.
    banked: u32 = 0,

    pub fn init() Sau {
        return .{};
    }

    /// Put the hardwired count in place, so the firmware's first read of
    /// TYPE is this core's region count rather than the zero the mapping
    /// starts at. This one write is what lets the secure boot past its
    /// capability check.
    pub fn prime(self: *Sau, core: anytype) !void {
        _ = self;
        try core.writeWord(memmap.sau.type_, geometry.type_value);
    }

    /// Keep TYPE read-only. A store that lands on it is counted and the
    /// count put back, the same rule the MPU window keeps over its own TYPE.
    pub fn poll(self: *Sau, core: anytype) !void {
        if (try core.readWord(memmap.sau.type_) != geometry.type_value) {
            self.refused +%= 1;
            try core.writeWord(memmap.sau.type_, geometry.type_value);
        }
    }

    /// Whether a store into the window asks for the banked pair to be put
    /// back in front of the firmware.
    pub const Cue = enum { none, rebank };

    /// File one store into the window under the region RNR names, and say
    /// whether the selection moved. CTRL is taken here rather than left for
    /// the next poll because a run can end between the store and the poll,
    /// and then the report would call an enabled SAU disabled.
    pub fn observe(self: *Sau, address: u32, value: u32) Cue {
        switch (address) {
            memmap.sau.rnr => {
                self.selected = geometry.selects(value);
                return .rebank;
            },
            memmap.sau.ctrl => self.ctrl = value,
            memmap.sau.rbar => {
                const slot = &self.table[self.selected];
                slot.* = Region.fromPair(value, slot.rlar);
                self.banked +%= 1;
            },
            memmap.sau.rlar => {
                const slot = &self.table[self.selected];
                slot.* = Region.fromPair(slot.rbar, value);
                self.banked +%= 1;
            },
            else => {},
        }
        return .none;
    }

    /// The pair the firmware should read back for the selected region.
    pub fn bankedPair(self: *const Sau) Region {
        return self.table[self.selected];
    }

    pub fn on(self: *const Sau) bool {
        return self.ctrl & field.ctrl_enable != 0;
    }

    /// Whether the firmware asked for memory outside every region to be
    /// treated as Non-Secure.
    pub fn outsideIsNonSecure(self: *const Sau) bool {
        return self.ctrl & field.ctrl_allns != 0;
    }

    pub fn programmed(self: *const Sau) u8 {
        var count: u8 = 0;
        for (self.table) |region| {
            if (region.enabled) count += 1;
        }
        return count;
    }

    pub fn callable(self: *const Sau) u8 {
        var count: u8 = 0;
        for (self.table) |region| {
            if (region.enabled and region.callable) count += 1;
        }
        return count;
    }

    pub fn quiet(self: *const Sau) bool {
        return !self.on() and self.programmed() == 0 and self.refused == 0;
    }
};
