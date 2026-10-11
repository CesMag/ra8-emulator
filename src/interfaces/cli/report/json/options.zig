//! The `options` object of `--report json` (RA8EMU-373): what the
//! extra-MRAM option sequencer programmed and every command it refused, the
//! same facts report/options.zig prints. Every key is always present.

/// The `options` object, keyed inside the document.
pub fn section(j: anytype, unit: anytype) !void {
    try j.open("options", '{');
    try j.field("programs", unit.programs);
    try j.field("config_sets", unit.config_sets);
    try j.field("live_cells", unit.otp.live());
    try j.field("rejected_outside_window", unit.illegal);
    try j.field("refused_command_locked", unit.locked_out);
    try j.field("refused_paused", unit.paused_kicks);
    try j.field("refused_outside_mode", unit.outside_mode);
    try j.field("refused_malformed", unit.malformed);
    try j.field("refused_otp_rewrites", unit.rewrites);
    try j.field("refused_mentryr_keyless", unit.entry.keyless);
    try j.field("refused_mentryr_narrow", unit.entry.narrow_writes);
    try j.field("setup_inits", unit.setup.kicks);
    try j.field("refused_msuinitr_keyless", unit.setup.keyless);
    try j.field("refused_msuinitr_narrow", unit.setup.narrow_writes);
    try j.field("refused_status_stores", unit.read_only);
    try j.field("refused_mrcps_stores", unit.code.refused);
    try j.field("lost_programs", unit.faulted);
    try j.close('}');
}
