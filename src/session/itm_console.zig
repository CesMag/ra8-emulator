//! Firmware's ITM printf on a plain `--console` run (RA8EMU-629).
//!
//! `ra8_log` and CMSIS `ITM_SendChar` write to ITM stimulus port 0 only
//! once DEMCR.TRCENA, ITM_TCR.ITMENA and ITM_TER bit 0 are set, which a
//! debugger does before the firmware runs. Without a debugger the PPB reads zero and those
//! images print nothing, so a `--console` run opens the ITM the way a probe
//! leaves it and shows port 0's lines as `itm: <line>`, the debugger's form.
const itm = @import("ra8_chip").periph.itm;
const memmap = @import("ra8_chip").core.memmap;
const clocks = @import("ra8_chip").periph.clocks;

/// The ITM as a probe leaves it: enabled, with port 0 on.
pub fn opened() itm.Itm {
    return .{ .tcr = itm.tcr_bits.itmena, .ter = 1 };
}

/// Put the registers a firmware polls into `memory`: DEMCR.TRCENA, every
/// stimulus port FIFOREADY, and TER and TCR as `port` holds them.
pub fn prime(memory: anytype, port: *const itm.Itm) !void {
    const demcr = try memory.readWord(memmap.scb.demcr);
    try memory.writeWord(memmap.scb.demcr, demcr | clocks.demcr_trcena);
    var stim: u32 = 0;
    while (stim < itm.limits.ports) : (stim += 1) try memory.writeWord(itm.base + stim * 4, itm.fifo_ready);
    try memory.writeWord(itm.base + itm.offsets.ter, port.ter);
    try memory.writeWord(itm.base + itm.offsets.tcr, port.tcr);
}
