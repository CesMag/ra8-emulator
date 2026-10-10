//! What an access the MPU refuses does to the core: the MemManage status it
//! latches, and the violation waiting to become one.
//!
//! Armv8-M refuses a store into a region whose RBAR.AP says read-only, at
//! both privilege levels, and takes a MemManage for it. The Zig core refuses
//! it through src/chip/core/cpu/mpu_check.zig; this file is what enforcement
//! records, kept apart so the bookkeeping can be tested on its own.
//!
//!   CFSR 0xE000_ED28, MMFSR is its low byte (DDI0553 D1.2.11)
//!     IACCVIOL  [0] an instruction fetch the MPU refused
//!     DACCVIOL  [1] a data access the MPU refused, which is this one
//!     MMARVALID [7] MMFAR holds the address that took it
//!   MMFAR 0xE000_ED34: the address, valid only while MMARVALID stands.

/// MemManage, exception 4 (DDI0553 B3.6).
const status = @import("../fault_status.zig");

pub const exception: u16 = 4;

/// The MMFSR bits a refused access sets: DACCVIOL with MMARVALID for a store
/// or a load, both being data accesses, and IACCVIOL on its own for a fetch. A refused fetch leaves MMFAR alone and
/// MMARVALID clear, because the address that took it is the PC the frame
/// already carries (DDI0553 D1.2.11).
pub const mmfsr = struct {
    pub const iaccviol: u32 = status.Cause.iaccviol.bit();
    pub const daccviol: u32 = status.Cause.daccviol.bit();
    pub const mmarvalid: u32 = status.Cause.mmarvalid.bit();
};

/// Why the region refused it. Both raise the same MemManage; they are kept
/// apart because a report that says only "refused" leaves the reader guessing
/// whether the firmware got the permissions wrong or the privilege wrong.
pub const Reason = enum {
    /// The region's own permissions: read-only against a store, execute-never
    /// against a fetch.
    permission,
    /// The region allows no unprivileged access at all, and the access was
    /// unprivileged.
    privilege,
    /// No region covered the address at all, and CTRL.PRIVDEFENA did not hand
    /// this access the default map. See src/chip/periph/mpu/mpu_background.zig.
    background,
};

/// Which direction the refused access went. The table in src/chip/periph/mpu/mpu.zig
/// answers with this too, because what a region allows is decided per
/// direction: read-only refuses a store and serves a load, execute-never
/// refuses a fetch and serves both, and privileged-only refuses all three.
pub const Kind = enum {
    /// A store into a region RBAR.AP made read-only, or one it keeps to
    /// privileged code.
    store,
    /// A fetch from a region RBAR.XN made execute-never, or one it keeps to
    /// privileged code.
    fetch,
    /// A load out of a region that allows no unprivileged access. No
    /// permission bit refuses a privileged load, so this is a privilege
    /// refusal every time.
    load,
};

/// One refused access: the instruction that made it, and the address it went
/// for. The PC matters as much as the address, because entry has to stack the
/// faulting instruction rather than whatever the run stopped on. For a fetch
/// the two are the same address.
pub const Violation = struct {
    pc: u32,
    address: u32,
    kind: Kind = .store,
    reason: Reason = .permission,
};

/// What enforcement has caught and what became of it.
pub const Latch = struct {
    /// The store waiting to become an exception, taken at the next boundary.
    pending: ?Violation = null,
    /// Accesses refused by an enabled region, of either kind.
    violations: u64 = 0,
    /// How many of those were fetches rather than data accesses.
    fetches: u64 = 0,
    /// How many were loads. Kept apart from stores because a load the model
    /// refuses has already been served by the engine, the same way a store
    /// has already landed: the count is what the report can still be honest
    /// about.
    loads: u64 = 0,
    /// How many were refused because the access was unprivileged and the
    /// region allows no unprivileged access, rather than on its permissions.
    privilege: u64 = 0,
    /// Of those, the ones that landed outside every enabled region rather
    /// than inside one that refused them.
    background: u64 = 0,
    /// Violations that reached a MemManage handler.
    faults: u64 = 0,
    /// Of those, the ones taken as a HardFault because SHCSR.MEMFAULTENA was
    /// clear and MemManage was therefore disabled. See
    /// src/chip/periph/mpu/mpu_escalate.zig.
    escalated: u64 = 0,
    /// Violations with no handler to reach: the vector table carries none, or
    /// the controller would not take it. No escalation to HardFault is
    /// modelled, so the run carries on from where the store left it.
    unhandled: u64 = 0,
    /// Further refused words of an access already latched. A store multiple
    /// puts one word per hook call, so the words after the first belong to
    /// the access that already stopped the run, not to a second violation.
    coalesced: u64 = 0,
    /// Times enforcement was armed, one per CTRL store that asked for it.
    arms: u64 = 0,
    /// Enforcement took itself off because a refused fetch had no handler to
    /// go to. Architecturally that is a HardFault escalation and then lockup;
    /// this model escalates neither, and leaving the trap up would re-refuse
    /// the same fetch at every boundary for the rest of the run without the
    /// PC ever moving. So the violation is counted once, the traps come off,
    /// and a later store to CTRL puts them back.
    stood_down: bool = false,

    /// A run whose firmware never enabled a protected region stays out of
    /// the report.
    pub fn quiet(self: *const Latch) bool {
        return self.arms == 0 and self.violations == 0;
    }

    /// Catch one refused access. Answers whether it is the one to stop on:
    /// the first is, and the rest of the same access are not.
    pub fn record(self: *Latch, hit: Violation) bool {
        if (self.pending != null) {
            self.coalesced +%= 1;
            return false;
        }
        self.pending = hit;
        self.violations +%= 1;
        if (hit.kind == .fetch) self.fetches +%= 1;
        if (hit.kind == .load) self.loads +%= 1;
        if (hit.reason == .privilege) self.privilege +%= 1;
        if (hit.reason == .background) self.background +%= 1;
        return true;
    }

    /// Take the pending violation, leaving nothing behind: the caller is
    /// about to turn it into an exception, and a violation is taken once.
    pub fn take(self: *Latch) ?Violation {
        const hit = self.pending orelse return null;
        self.pending = null;
        return hit;
    }
};
