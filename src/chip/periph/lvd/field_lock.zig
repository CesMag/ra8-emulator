//! FSAMP: the PVD filter divider only takes a store while the filter it
//! divides is switched off.
//!
//! Its own file rather than a prong inside lvd.zig, the way
//! spi/enable_lock.zig and mipi/phy/pll_lock.zig sit beside their blocks.
//!
//! THE RULE. HUM Ch 8.2.4 "PVDmCR0" p 305 and Ch 8.2.5 "PVDnCR0" p 306,
//! quoted in ra8_lvd_runtime.c at ra8_lvd_set_filter: "FSAMP can only be
//! modified while DFDIS = 1". The helper is built around it and reaches CR0
//! three times where one store would do: set DFDIS, write FSAMP, and only
//! then drop DFDIS again when the caller asked for the filter to run. A
//! model that takes the store either way makes that sequence pointless and
//! lets an image that reprograms the divider under a running filter pass
//! here and keep the old divider on the bench.
//!
//! THE GATE IS THE DFDIS BIT STANDING BEFORE THE STORE, not the one the
//! store carries. That is what makes the driver's second write land: it sets
//! DFDIS in its own earlier write, so by the time the FSAMP value arrives the
//! filter is already disabled.
//!
//! A REFUSAL IS COUNTED ONLY WHEN THE STORE WOULD HAVE MOVED FSAMP. Every
//! driver path reaches CR0 through a read-modify-write that carries the
//! current divider along unchanged, so counting every store made with the
//! filter running would count the driver's own correct sequence as a
//! violation. The other bits of the store land either way: setting DFDIS is
//! exactly what the driver is doing in the write before this one.
//!
//! WHAT IS NOT MODELLED, AND NOT GUESSED: what the part does with the value
//! it refuses. Nothing in either tree says whether it is dropped or held for
//! the next time the filter stops, so this takes the narrower reading and
//! keeps the field as it was.
//!
//! THE OTHER HALF OF THIS VEIN IS DELIBERATELY NOT HERE. PVDmCMPCR.PVDLVL
//! carries the same shape of rule (HUM Ch 8.2.2 p 303, quoted in
//! ra8_lvd_api.h:142: PVDLVL "can only be changed while **every**
//! PVDmCMPCR.PVDE and PVDnCMPCR.PVDE bit is 0"), and enforcing it here turns
//! out not to be a one-line change. The legal way to move a threshold is
//! ra8_lvd_set_threshold's drop-PVDE, store, restore-PVDE, and lvd.zig's
//! evaluate() deliberately treats a re-enable as establishing a baseline
//! rather than as a crossing. Put those together and no legal threshold
//! change can ever latch DET, which on a board model whose rail is a fixed
//! 3.3 V means DET could never latch at all. Landing that rule needs a
//! decision about what PVDE re-enable means when the rail already sits below
//! Vdet, which is a model-behaviour call with its own evidence, so it gets
//! its own slice rather than riding along with this one.
const regs = @import("regs.zig");

/// The refusals, counted per block: which channel reprogrammed its divider
/// under a running filter is not something a reader would act on differently.
pub const Locked = struct {
    /// FSAMP changes dropped because the digital filter was still running.
    filters: u32 = 0,

    pub fn quiet(self: *const Locked) bool {
        return self.filters == 0;
    }

    /// What a store to PVDmCR0 actually lands.
    pub fn filter(self: *Locked, current: u8, value: u8) u8 {
        if (current & regs.control.dfdis != 0) return value;
        if (value & regs.control.fsamp == current & regs.control.fsamp) return value;
        self.filters +%= 1;
        return (value & ~regs.control.fsamp) | (current & regs.control.fsamp);
    }
};
