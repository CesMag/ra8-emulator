//! The `modules` array of `--report json` (RA8EMU-1139): the ThreadX
//! modules the Module Manager had loaded as the run ended, read the way the
//! text report reads them (src/session/txm_report.zig).
//!
//! The key is left out when no module is loaded, so a document from a run
//! without modules is unchanged. Each entry carries its name (null when
//! unreadable), state, and code and data start and size.
const txm_report = @import("ra8_session").txm_report;
const txm = @import("ra8_session").txm_modules;

/// The `modules` array, or nothing when `found` lists none.
pub fn section(j: anytype, found: ?*const txm_report.Listed) !void {
    const listed = found orelse return;
    if (listed.count == 0) return;
    try j.open("modules", '[');
    for (listed.rows(), 0..) |entry, index| try one(j, entry, listed.name(index));
    try j.close(']');
}

fn one(j: anytype, entry: txm.Module, name: ?[]const u8) !void {
    try j.open(null, '{');
    try j.field("name", name);
    try j.field("state", entry.state.text());
    try j.field("code_start", entry.code_start);
    try j.field("code_size", entry.code_size);
    try j.field("data_start", entry.data_start);
    try j.field("data_size", entry.data_size);
    try j.close('}');
}
