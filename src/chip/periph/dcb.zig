//! The debug control registers a firmware can see: DHCSR, DCRSR and DCRDR
//! at 0xE000_EDF0 (DDI0553, Debug Control Block).
//!
//! Firmware mostly reads DHCSR.C_DEBUGEN to learn whether a debugger is
//! attached, for instance before a BKPT in an assert handler. The debug
//! core is that debugger, so C_DEBUGEN reads one once it attaches, and a
//! firmware write cannot change it. With C_DEBUGEN set, a write carrying
//! DBGKEY may set C_HALT, which halts the core once the store retires, and
//! C_STEP and C_MASKINTS. With C_STEP kept, the next resume runs one
//! instruction and halts again. C_MASKINTS reads back, and src/chip/periph/nvic/nvic.zig reads it to hold back
//! PendSV, SysTick and external interrupts (`masksInterrupts`)
//! yet. C_HALT is not
//! kept: the core only runs again after the debugger resumes it, and a
//! resume clears it. S_REGRDY always reads one because a transfer finishes
//! at once.
//!
//! DCRSR and DCRDR move a core register only while the core is in halting
//! debug state, which firmware never runs in, so a DCRSR write from
//! firmware is held but moves nothing. DCRDR is a plain data word, which
//! debug monitors use to pass values to the debugger. DCRSR is write-only
//! and reads zero. DEMCR at 0xE000_EDFC belongs to src/chip/periph/clocks.zig;
//! this file only names the two monitor bits in it.
//!
//! DFSR at 0xE000_ED30 records why the core last took a debug event: a
//! halt, a breakpoint or a DWT trap. Its bits are sticky and a write of one
//! clears them.
pub const base: u32 = 0xE000_EDF0;
pub const dfsr_address: u32 = 0xE000_ED30;
pub const demcr_address: u32 = 0xE000_EDFC;

pub const offsets = struct {
    pub const dhcsr: u32 = 0x0;
    pub const dcrsr: u32 = 0x4;
    pub const dcrdr: u32 = 0x8;
};

/// The bytes the block spans from `base`, stopping short of DEMCR.
pub const span: u32 = 0xC;

pub const dhcsr_bits = struct {
    pub const c_debugen: u32 = 1 << 0;
    pub const c_halt: u32 = 1 << 1;
    pub const c_step: u32 = 1 << 2;
    pub const c_maskints: u32 = 1 << 3;
    pub const s_regrdy: u32 = 1 << 16;
    pub const s_halt: u32 = 1 << 17;
    /// DBGKEY, in [31:16] of a write. Without it the write is dropped.
    pub const key: u32 = 0xA05F;
    pub const key_shift: u5 = 16;
    /// The controls a keyed write keeps.
    pub const kept: u32 = c_step | c_maskints;
};

pub const dfsr_bits = struct {
    pub const halted: u32 = 1 << 0;
    pub const bkpt: u32 = 1 << 1;
    pub const dwttrap: u32 = 1 << 2;
};

pub const demcr_bits = struct {
    /// TRCENA: the DWT and ITM are enabled.
    pub const trcena: u32 = 1 << 24;
    /// MON_EN: a debug event with halting debug off takes DebugMonitor.
    pub const mon_en: u32 = 1 << 16;
    /// MON_PEND: DebugMonitor is pending.
    pub const mon_pend: u32 = 1 << 17;
};

pub const dcrsr_bits = struct {
    pub const regsel: u32 = 0x7F;
    pub const regwnr: u32 = 1 << 16;
};

/// DebugCanMaskInts (DDI0553B.y E2.1.93) for a DHCSR word: C_MASKINTS
/// counts only with C_DEBUGEN set. S_SDE is not modelled, so Secure
/// debug counts as enabled.
pub fn masksInterrupts(dhcsr: u32) bool {
    const both = dhcsr_bits.c_debugen | dhcsr_bits.c_maskints;
    return dhcsr & both == both;
}

pub const Dcb = struct {
    /// C_DEBUGEN: a debugger is attached. Only the debugger sets it.
    debugen: bool = false,
    controls: u32 = 0,
    selector: u32 = 0,
    data: u32 = 0,
    /// DFSR, as the debug events so far latched it.
    dfsr: u32 = 0,
    /// A keyed C_HALT write the core has not yet been halted for.
    halt_asked: bool = false,
    /// A register changed since memory last showed the register file.
    changed: bool = false,

    /// The debugger attached: C_DEBUGEN reads one from now on.
    pub fn attachDebugger(self: *Dcb) void {
        self.debugen = true;
        self.changed = true;
    }

    /// The register at `offset` as a read sees it, or null when the
    /// offset is not one of these registers.
    pub fn peek(self: *const Dcb, offset: u32) ?u32 {
        return switch (offset) {
            offsets.dhcsr => @as(u32, @intFromBool(self.debugen)) | self.controls | dhcsr_bits.s_regrdy,
            offsets.dcrsr => 0,
            offsets.dcrdr => self.data,
            else => null,
        };
    }

    /// A firmware store. False when the offset is not one of these.
    pub fn write(self: *Dcb, offset: u32, value: u32) bool {
        switch (offset) {
            offsets.dhcsr => self.control(value),
            offsets.dcrsr => self.selector = value & (dcrsr_bits.regsel | dcrsr_bits.regwnr),
            offsets.dcrdr => self.data = value,
            else => return false,
        }
        self.changed = true;
        return true;
    }

    /// A debug event happened: latch its DFSR bits.
    pub fn latch(self: *Dcb, bits: u32) void {
        if (bits == 0) return;
        self.dfsr |= bits;
        self.changed = true;
    }

    /// A firmware store to DFSR: each bit written as one is cleared.
    pub fn clearStatus(self: *Dcb, value: u32) void {
        self.dfsr &= ~value;
        self.changed = true;
    }

    /// DHCSR.C_STEP with halting debug on: a resume is a single step.
    pub fn stepping(self: *const Dcb) bool {
        return self.debugen and self.controls & dhcsr_bits.c_step != 0;
    }

    /// Whether a C_HALT write is waiting for the core to halt, and forget
    /// it once asked.
    pub fn takeHalt(self: *Dcb) bool {
        defer self.halt_asked = false;
        return self.halt_asked;
    }

    fn control(self: *Dcb, value: u32) void {
        if (value >> dhcsr_bits.key_shift != dhcsr_bits.key or !self.debugen) return;
        self.controls = value & dhcsr_bits.kept;
        if (value & dhcsr_bits.c_halt != 0) self.halt_asked = true;
    }
};
