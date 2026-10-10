//! The R-Switch register cluster: where each sub-block sits and which
//! registers inside it this tree answers for.
//!
//! One file of names so the mode machine, the PHY and the board all say the
//! same thing about an address. Everything in the cluster that is config
//! reflect only (MFWD, ESWM's media mux, the ETHA queue configuration) is
//! deliberately absent: the bus already remembers what was written to an
//! address nothing models, which is the whole of what dev's flat shadow did
//! for those registers.

/// Sub-block bases inside the cluster. Silicon facts, not options.
pub const cluster = struct {
    pub const mfwd: u32 = 0x403C_0000;
    pub const eswm: u32 = 0x403C_8000;
    pub const coma: u32 = 0x403C_9000;
    pub const etha0: u32 = 0x403C_A000;
    pub const rmac0: u32 = 0x403C_B000;
    pub const etha1: u32 = 0x403C_C000;
    pub const rmac1: u32 = 0x403C_D000;
    pub const gwca0: u32 = 0x403C_E000;
    /// ETHA/RMAC come in pairs, one per switch port.
    pub const port_count: usize = 2;
};

/// ETHA, the per-port agent. Only the mode pair is modelled here.
pub const etha = struct {
    pub const eamc: u32 = 0x0000;
    pub const eams: u32 = 0x0004;
    /// The window this tree claims: the two mode registers, nothing else.
    pub const mode_span: u32 = 0x0008;
    pub const opc_mask: u32 = 0x3;
};

/// GWCA, the CPU agent. The mode pair and the AXI-init handshake.
pub const gwca = struct {
    pub const gwmc: u32 = 0x0000;
    pub const gwms: u32 = 0x0004;
    pub const mode_span: u32 = 0x0008;
    pub const gwarirm: u32 = 0x0380;
    pub const arirm_span: u32 = 0x0004;
    /// GWARIRM.ARIOG asks for the AXI init, GWARIRM.ARR answers it.
    pub const ariog: u32 = 1 << 0;
    pub const arr: u32 = 1 << 1;
    pub const opc_mask: u32 = 0x3;
    /// The descriptor control: where the chains are, the TX request words,
    /// and the per-queue configuration.
    pub const gwdcbac0: u32 = 0x0194;
    pub const gwdcbac1: u32 = 0x0198;
    pub const base_span: u32 = 0x0008;
    pub const gwtrc0: u32 = 0x0200;
    pub const gwtrc1: u32 = 0x0204;
    pub const request_span: u32 = 0x0008;
    /// Queues one GWTRC word carries, bit zero being the lowest of them.
    pub const request_bits: u32 = 32;
    pub const gwdcc: u32 = 0x0400;
    pub const queue_count: u32 = 32;
    pub const config_span: u32 = queue_count * 4;
    /// GWDCC.DQT: clear marks a reception queue, set a transmission one.
    pub const dqt: u32 = 1 << 11;
    /// GWDCC.BALR asks for a base-address reload and is done when read.
    pub const balr: u32 = 1 << 24;
};

/// COMA, the cluster's common block. The buffer-pool init handshake.
pub const coma = struct {
    pub const cabpirm: u32 = 0x0140;
    pub const cabpirm_span: u32 = 0x0004;
    /// CABPIRM.BPIOG asks for the pool init, CABPIRM.BPR answers it.
    pub const bpiog: u32 = 1 << 0;
    pub const bpr: u32 = 1 << 1;
};

/// RMAC, the per-port MAC. Only MPSM, the MDIO management frame, is
/// modelled: the rest of the MAC's configuration reads back from the bus.
pub const rmac = struct {
    pub const mpsm: u32 = 0x0000;
    pub const mpsm_span: u32 = 0x0004;
    /// PSME starts the frame and clears itself when it has been carried out.
    pub const psme: u32 = 1 << 0;
    /// MFF selects the Clause-45 frame format.
    pub const mff: u32 = 1 << 2;
    pub const pda_shift: u5 = 3;
    pub const pda_mask: u32 = 0x1F;
    pub const pra_shift: u5 = 8;
    pub const pra_mask: u32 = 0x1F;
    pub const pop_shift: u5 = 13;
    pub const pop_mask: u32 = 0x3;
    pub const prd_shift: u5 = 16;
    pub const prd_mask: u32 = 0xFFFF;
};

/// MPSM.POP in a Clause-22 frame. The other two codes belong to Clause-45
/// frames and are not management operations here.
pub const Op = enum(u2) {
    c45_address = 0,
    write = 1,
    read = 2,
    c45_read = 3,
};

/// The data field of a management frame, in place.
pub fn dataOf(mpsm: u32) u16 {
    return @truncate((mpsm >> rmac.prd_shift) & rmac.prd_mask);
}

/// The same frame carrying `value` as its data and nothing else changed.
pub fn withData(mpsm: u32, value: u16) u32 {
    const kept = mpsm & ~(rmac.prd_mask << rmac.prd_shift);
    return kept | (@as(u32, value) << rmac.prd_shift);
}
