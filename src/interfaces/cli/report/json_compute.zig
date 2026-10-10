//! The `compute` object of `--report json` (RA8EMU-377): what the Ethos-U55
//! NPU was asked to do, what it moved, and every kick it refused, the same
//! facts report/compute.zig prints. Every key is always present, zero on a
//! part without the NPU or a run that never touched it.
const Board = @import("ra8_board").board.Board;

/// The `compute` object, keyed inside the document after `analog`.
pub fn section(j: anytype, board: *Board) !void {
    const unit = &board.npu;
    try j.open("compute", '{');
    try j.field("touched", !unit.quiet());
    try j.field("reads", unit.reads);
    try j.field("writes", unit.writes);
    try j.field("jobs", unit.jobs);
    try j.field("moved", unit.moved);
    try j.field("last_op", if (unit.last_op) |op| op.label() else null);
    try j.field("last_bytes", unit.last_bytes);
    try j.field("last_check", unit.last_check);
    try j.field("refused_unknown_ops", unit.unknown_ops);
    try j.field("refused_malformed", unit.malformed);
    try j.field("refused_unmapped_region", unit.unmapped_region);
    try j.field("faulted_unreachable", unit.unreachable_memory);
    try j.field("in_place", unit.in_place);
    try j.field("short_jobs", unit.short_jobs);
    try j.field("short_bytes", unit.short_bytes);
    try j.field("refused_id_status_stores", unit.faked);
    const vela = unit.vela;
    try j.open("vela", '{');
    try j.field("kicks", vela.kicks());
    try j.field("jobs", vela.jobs);
    try j.field("moved", vela.moved);
    try j.field("refused_unmodelled", vela.unmodelled);
    try j.field("refused_malformed", vela.malformed);
    try j.field("faulted", vela.refused);
    try j.close('}');
    try j.close('}');
}
