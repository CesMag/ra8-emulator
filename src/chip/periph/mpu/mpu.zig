//! MPU_TYPE: how many data regions the core says it has, and why a zero there
//! parks an image in `main`.
//!
//! The PPB is plain RAM in this model, so every MPU register a firmware writes
//! lands and reads back for free. TYPE is the one that does not work that way:
//! it is read-only and hardwired, and nothing writes it, so it read as zero.
//! `ra8_mpu_configure` opens by validating capacity, `if (cfg.region_count >
//! dregionCount()) return .invalid_arg`, and every RA8 image that programs the
//! MPU asks for at least one region. So the call was rejected before it touched
//! a single register, and `main` spun forever on the `wfi` beside its call site:
//!
//!     bl      ra8_mpu_configure
//!     cmp     r3, #0
//!     beq.n   main+0x22        ; the rest of main, never taken
//!     wfi                      ; ... and the branch back to it
//!
//! threadx_mpu_partition_demo never reached `_tx_initialize_kernel_enter` for
//! this reason: no SysTick armed, no interrupt taken, nothing to show for a
//! whole budget. dev's C emulator seeds the same word for the same reason, and
//! says so at `k_mpu_type_seed` in emu_exc.h: 8 data regions, matching the
//! Cortex-M85 the RA8D2 carries. That count is taken from there, not guessed.
//!
//!   MPU_TYPE 0xE000_ED90 (DDI0553 D1.2.16)
//!     DREGION [15:8] read-only, hardwired: the number of data regions
//!     SEPARATE [0]   read-only, zero: one unified region set
//!
//! TWO THINGS THIS BLOCK DOES NOT DO, both measured with
//! fw/probe/mpuregions.c rather than assumed, and both left for later slices.
//!
//! RBAR/RLAR ARE BANKED THROUGH RNR, and that is the second thing this block
//! had to learn. On silicon RNR selects which of the eight region pairs the
//! one RBAR/RLAR address reaches. The PPB is plain RAM here and RBAR is one
//! word, so every region programmed landed on top of the last one, and the
//! table was read back at a poll rather than as it was written. That is not a
//! cosmetic gap: `ra8_mpu_configure` programs the table and then CLEARS THE
//! UNUSED TAIL, one `RNR = i; RLAR = 0` per unimplemented region, so the last
//! write any configuration leaves behind is a zeroed RLAR. Read back over RAM
//! that says the firmware enabled nothing, and threadx_mpu_partition_demo
//! reported "0 of 8 region(s) enabled" after programming four.
//!
//! So the writes are watched instead of the words: `observe` takes each store
//! into the window and files it under the region RNR names, and a store to RNR
//! puts that region's pair back into the RAM the firmware reads, which is what
//! makes a readback after an RNR change give the right region. The three alias
//! pairs reach the three regions after the selected one, which is how a driver
//! programs four regions without touching RNR again.
//!
//! THE TABLE IS WHAT ENFORCEMENT READS. A store into a read-only region is a
//! MemManage violation on silicon, and the Zig core refuses it through
//! src/chip/core/cpu/mpu_check.zig: src/chip/periph/mpu/fault.zig holds what it
//! catches, and this block is the table it reads. So a
//! region captured wrongly here is now a fault taken wrongly rather than a
//! line in the report, which is why `observe` says what each store meant
//! rather than leaving the caller to work it out from the address.
const memmap = @import("../../core/memmap.zig");
pub const fault = @import("fault.zig");

/// The register block's fixed shape: how many data regions this core reports,
/// and where DREGION sits in TYPE.
pub const geometry = struct {
    /// Data regions the modelled core implements. dev's emu_exc.h seeds
    /// MPU_TYPE with 0x0000_0800 and calls it "8 data regions (matches the
    /// M85 MPU)"; emu_mpu.c carries the same 8 as its table length.
    pub const regions: u8 = 8;
    pub const dregion_shift: u5 = 8;
    /// What a read of TYPE gives back. SEPARATE reads zero: the Armv8-M MPU
    /// has one unified region set, not split instruction and data sets.
    pub const type_value: u32 = @as(u32, regions) << dregion_shift;

    /// The region a select value names, wrapped into the implemented set the
    /// way a 3-bit RNR field does with 8 regions.
    pub fn selects(rnr: u32) u8 {
        return @intCast(rnr % regions);
    }
};

pub const field = struct {
    /// CTRL[0] ENABLE, [1] HFNMIENA, [2] PRIVDEFENA.
    pub const ctrl_enable: u32 = 1 << 0;
    pub const ctrl_hfnmiena: u32 = 1 << 1;
    pub const ctrl_privdefena: u32 = 1 << 2;
    /// RBAR[0] XN, [2:1] AP. AP[1] (bit 1) allows unprivileged access at all;
    /// AP[2] (bit 2) makes the region read-only at both privilege levels.
    pub const rbar_xn: u32 = 1 << 0;
    pub const rbar_ap_unprivileged: u32 = 1 << 1;
    pub const rbar_ap_ro: u32 = 1 << 2;
    /// RLAR[0] EN, the region-enable bit.
    pub const rlar_enable: u32 = 1 << 0;
    /// BASE and LIMIT hold [31:5]: regions are aligned and sized in 32 bytes.
    pub const address: u32 = 0xFFFF_FFE0;
    /// A LIMIT is inclusive, so the low five bits the field cannot hold read
    /// as ones rather than zeros.
    pub const limit_low: u32 = 0x1F;
};

/// One data region as the firmware left it: the inclusive span it covers, and
/// the three bits that decide which accesses into it are allowed.
/// The Non-secure MPU's copy on the Zig core's bus. src/chip/periph/mpu/ns.zig.
pub const ns = @import("ns.zig");
pub const background = @import("background.zig");
pub const escalate = @import("escalate.zig");

pub const Region = struct {
    base: u32 = 0,
    limit: u32 = 0,
    read_only: bool = false,
    executable: bool = true,
    /// RBAR.AP[1]: whether unprivileged code may touch the region at all. A
    /// region without it is privileged-only, and an unprivileged access to it
    /// is refused whichever direction it goes.
    unprivileged: bool = false,
    enabled: bool = false,
    /// The two words exactly as the firmware wrote them. Kept whole rather
    /// than rebuilt from the fields above, so putting a region back in front
    /// of the firmware after an RNR change returns what it programmed,
    /// including the attribute and shareability bits this model does not read.
    rbar: u32 = 0,
    rlar: u32 = 0,

    /// Read one region out of the RBAR/RLAR pair that programs it.
    pub fn fromPair(rbar: u32, rlar: u32) Region {
        return .{
            .base = rbar & field.address,
            .limit = (rlar & field.address) | field.limit_low,
            .read_only = rbar & field.rbar_ap_ro != 0,
            .executable = rbar & field.rbar_xn == 0,
            .unprivileged = rbar & field.rbar_ap_unprivileged != 0,
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

    /// Whether this region refuses one access, and on which of the two
    /// grounds. Privilege is checked first because it refuses a load as well,
    /// and because a privileged-only region says nothing about what
    /// privileged code may do there.
    pub const Refusal = enum { allowed, permission, privilege };

    pub fn refuses(self: Region, kind: fault.Kind, privileged: bool) Refusal {
        if (!privileged and !self.unprivileged) return .privilege;
        return switch (kind) {
            // No permission bit refuses a load: read-only is about stores and
            // execute-never is about fetches, so a privileged load is served
            // by every region this model knows how to program.
            .load => .allowed,
            .store => if (self.read_only) .permission else .allowed,
            .fetch => if (self.executable) .allowed else .permission,
        };
    }

    /// Whether any access into this region could be refused, which is what
    /// decides if enforcement needs a trap over its span at all.
    pub fn guarded(self: Region) bool {
        return self.read_only or !self.executable or !self.unprivileged;
    }
};

/// The MPU window: the hardwired count the firmware reads out of it, and the
/// region table it programmes into it.
pub const Mpu = struct {
    table: [geometry.regions]Region = @splat(.{}),
    /// RNR as the firmware last left it.
    selected: u8 = 0,
    /// CTRL as the firmware last left it, so the report can say which of the
    /// three configuration bits it asked for.
    ctrl: u32 = 0,
    /// Transitions of CTRL.ENABLE, so a run that turns the MPU on and off
    /// around a reprogramme is distinguishable from one that never used it.
    enables: u32 = 0,
    disables: u32 = 0,
    /// Stores to TYPE turned away, the read-only rule this block enforces.
    refused: u32 = 0,
    /// Stores into a banked RBAR or RLAR, so a run that programmed the table
    /// is distinguishable from one that only read TYPE and gave up.
    banked: u32 = 0,

    pub fn init() Mpu {
        return .{};
    }

    /// Put the hardwired count in place, so the firmware's first read of TYPE
    /// is this core's region count rather than the zero the mapping starts at.
    pub fn prime(self: *Mpu, core: anytype) !void {
        _ = self;
        try core.writeWord(memmap.mpu.type_, geometry.type_value);
    }

    /// Read the window: keep TYPE read-only, and see which way CTRL.ENABLE
    /// has moved. A word store to CTRL has already been taken in `observe`,
    /// so the edge it counts here is the one that never reached it: a narrow
    /// store, which the window hook leaves to the RAM underneath. The region table is NOT read here: it is built from the
    /// stores themselves in `observe`, because the last store any
    /// configuration leaves behind is a cleared RLAR for the unused tail and
    /// a poll would only ever see that.
    pub fn poll(self: *Mpu, core: anytype) !void {
        if (try core.readWord(memmap.mpu.type_) != geometry.type_value) {
            self.refused +%= 1;
            try core.writeWord(memmap.mpu.type_, geometry.type_value);
        }
        const ctrl = try core.readWord(memmap.mpu.ctrl);
        const was_on = self.ctrl & field.ctrl_enable != 0;
        const is_on = ctrl & field.ctrl_enable != 0;
        if (is_on and !was_on) self.enables +%= 1;
        if (was_on and !is_on) self.disables +%= 1;
        self.ctrl = ctrl;
    }

    /// Which region a store at this address programs, and which half of its
    /// pair. RNR names the first; each alias pair reaches the region after
    /// the one before it, which is how a driver programs four in a row
    /// without touching RNR again.
    const Target = struct { offset: u2, limit_half: bool };

    fn targetOf(address: u32) ?Target {
        return switch (address) {
            memmap.mpu.rbar => .{ .offset = 0, .limit_half = false },
            memmap.mpu.rlar => .{ .offset = 0, .limit_half = true },
            memmap.mpu.rbar_a1 => .{ .offset = 1, .limit_half = false },
            memmap.mpu.rlar_a1 => .{ .offset = 1, .limit_half = true },
            memmap.mpu.rbar_a2 => .{ .offset = 2, .limit_half = false },
            memmap.mpu.rlar_a2 => .{ .offset = 2, .limit_half = true },
            memmap.mpu.rbar_a3 => .{ .offset = 3, .limit_half = false },
            memmap.mpu.rlar_a3 => .{ .offset = 3, .limit_half = true },
            else => null,
        };
    }

    /// The region a pair at this offset from RNR programs.
    pub fn banks(self: *const Mpu, offset: u2) u8 {
        return geometry.selects(@as(u32, self.selected) + offset);
    }

    /// What a store into the window asks of the engine above this block.
    pub const Cue = enum {
        /// Nothing beyond what the store already did to the table.
        none,
        /// RNR moved: put the newly selected pairs back in front of the
        /// firmware, so a read after the change gives the region it picked.
        rebank,
        /// CTRL was written: enforcement follows ENABLE, so the traps over
        /// the read-only regions are rebuilt or taken off.
        rearm,
    };

    /// File one store into the window under the region RNR names, and say
    /// what else it asks for. CTRL is not folded in here: the enable and
    /// disable edges are counted at the boundary poll, and this only cues
    /// the engine to follow the bit the store carried.
    pub fn observe(self: *Mpu, address: u32, value: u32) Cue {
        if (address == memmap.mpu.rnr) {
            self.selected = geometry.selects(value);
            return .rebank;
        }
        if (address == memmap.mpu.ctrl) {
            // The store IS the new CTRL. Leaving the word for the next poll
            // to pick out of the PPB left every live rule reading a stale
            // one: enforcement asking whether the MPU is on, and the
            // background asking about PRIVDEFENA, both run at access time,
            // long before the next poll comes round.
            const was_on = self.ctrl & field.ctrl_enable != 0;
            const is_on = value & field.ctrl_enable != 0;
            if (is_on and !was_on) self.enables +%= 1;
            if (was_on and !is_on) self.disables +%= 1;
            self.ctrl = value;
            return .rearm;
        }
        const target = targetOf(address) orelse return .none;
        const region = &self.table[self.banks(target.offset)];
        const pair = if (target.limit_half)
            [2]u32{ region.rbar, value }
        else
            [2]u32{ value, region.rlar };
        region.* = Region.fromPair(pair[0], pair[1]);
        self.banked +%= 1;
        return .none;
    }

    /// The RBAR and RLAR words the firmware should see at this offset from
    /// RNR, so a read after an RNR change gives back the region it selected
    /// rather than whatever the last store happened to leave in the word.
    pub fn pairFor(self: *const Mpu, offset: u2) [2]u32 {
        const region = self.table[self.banks(offset)];
        return .{ region.rbar, region.rlar };
    }

    pub fn on(self: *const Mpu) bool {
        return self.ctrl & field.ctrl_enable != 0;
    }

    pub fn privilegedDefault(self: *const Mpu) bool {
        return self.ctrl & field.ctrl_privdefena != 0;
    }

    /// How many regions the firmware left enabled.
    pub fn programmed(self: *const Mpu) u8 {
        var count: u8 = 0;
        for (self.table) |region| {
            if (region.enabled) count += 1;
        }
        return count;
    }

    /// How many of those are read-only, the ones enforcement will care about.
    pub fn readOnly(self: *const Mpu) u8 {
        var count: u8 = 0;
        for (self.table) |region| {
            if (region.enabled and region.read_only) count += 1;
        }
        return count;
    }

    /// The enabled region covering an address, highest-numbered first the way
    /// the architecture resolves an overlap, or null when none does.
    pub fn regionFor(self: *const Mpu, at: u32) ?Region {
        var i: usize = self.table.len;
        while (i > 0) {
            i -= 1;
            if (self.table[i].covers(at)) return self.table[i];
        }
        return null;
    }
};
