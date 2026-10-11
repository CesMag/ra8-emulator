//! The `icu`, `pinfunc`, `options`, `part` and `backup` objects of
//! `--report json` (RA8EMU-373): the event links and external-IRQ pins, the
//! pin-function writes, the extra-MRAM option sequencer, the modelled part
//! and its geometry, and the battery-backed corner (PRCR, VBTBKRn, the VBATT
//! control file), the same facts report/icu.zig, pinfunc.zig, options.zig,
//! part.zig and backup.zig print. Every key is always present.
const Board = @import("ra8_board").board.Board;
const part = @import("ra8_chip").core.part;
const json_options = @import("options.zig");

/// The five objects, keyed inside the document after `capture`.
pub fn section(j: anytype, board: *Board) !void {
    try icu(j, board);
    try pinfunc(j, &board.pinfunc);
    try json_options.section(j, &board.options);
    try partInfo(j, board.part);
    try backup(j, board);
}

fn icu(j: anytype, board: *Board) !void {
    const unit = &board.events;
    try j.open("icu", '{');
    try j.field("raised", unit.raised);
    try j.field("pended", unit.pends);
    try j.field("unrouted", unit.unlinked);
    try j.field("repended", unit.repends);
    try j.field("irq_pins_configured", unit.pins.configured());
    try j.field("irq_pin_rewrites_while_routed", unit.pins.rewrites_while_routed);
    try j.close('}');
}

fn pinfunc(j: anytype, unit: anytype) !void {
    try j.open("pinfunc", '{');
    try j.field("programmed", unit.programmed);
    try j.field("refused_unlocked", unit.guard.refused);
    try j.field("glitched", unit.ordering.glitched);
    try j.field("ignored_keys", unit.guard.ignored_keys);
    try j.close('}');
}

fn partInfo(j: anytype, which: part.Part) !void {
    const geometry = part.map.of(which);
    try j.open("part", '{');
    try j.field("name", which.label());
    try j.field("mram_base", geometry.mram_base);
    try j.field("mram_bytes", geometry.mram_bytes);
    try j.field("sram_base", geometry.sram_base);
    try j.field("sram_bytes", geometry.sram_bytes);
    try j.field("cpu0_tcm_bytes", geometry.cpu0TcmBytes());
    try j.field("cpu0_cache_bytes", 2 * geometry.cpu0_cache_bank_bytes);
    try j.field("cpu1_tcm_bytes", geometry.cpu1TcmBytes());
    try j.field("cpu1_cache_bytes", 2 * geometry.cpu1_cache_bank_bytes);
    try j.field("source", geometry.source);
    try j.close('}');
}

fn backup(j: anytype, board: *Board) !void {
    const prcr = &board.protection;
    const unit = &board.backup;
    try j.open("backup", '{');
    try j.open("prcr", '{');
    try j.field("unlocks", prcr.unlocks);
    try j.field("rejected_keys", prcr.bad_key);
    try j.field("groups", prcr.groups);
    try j.close('}');
    try j.field("vbtbkr_writes", unit.writes);
    try j.field("dropped_locked", unit.dropped_locked);
    try j.field("dropped_disabled", unit.dropped_disabled);
    try j.field("last_drop", @tagName(unit.lastDrop()));
    try j.open("control", '{');
    try j.field("writes", unit.control.writes);
    try j.field("flags_cleared", unit.control.cleared);
    try j.field("vbae", unit.control.vbaeSet());
    try j.field("refused", unit.control.refused);
    try j.field("dropped_locked", unit.control_locked);
    try j.close('}');
    try j.close('}');
}
