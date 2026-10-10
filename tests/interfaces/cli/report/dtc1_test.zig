//! Covers src/interfaces/cli/report/dtc1.zig: DTC1's lines in the report.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const dtc = ra8.chip.periph.dtc;
const report_dtc1 = cli_app.report.dtc1;

fn render(unit: *const dtc.Dtc) !std.Io.Writer.Allocating {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer text.deinit();
    try report_dtc1.section(unit, &text.writer);
    return text;
}

test "an untouched DTC1 adds nothing to the report" {
    const unit = dtc.Dtc.init();
    var text = try render(&unit);
    defer text.deinit();
    try std.testing.expectEqual(@as(usize, 0), text.written().len);
}

test "a DTC1 that moved data reports it as CPU1's" {
    var unit = dtc.Dtc.init();
    unit.activations = 3;
    unit.units = 3;
    unit.bytes = 12;
    unit.completions = 1;
    unit.dtcvbr = 0x2200_0400;
    var text = try render(&unit);
    defer text.deinit();
    try std.testing.expectEqualStrings(
        "DTC1 (CPU1): 3 activation(s), 3 unit(s) / 12 byte(s) moved, 1 descriptor(s) finished, DTCVBR 0x22000400\n",
        text.written(),
    );
}

test "a refused DTC1 activation is called out" {
    var unit = dtc.Dtc.init();
    unit.refused = 2;
    unit.last_refusal = .stopped;
    var text = try render(&unit);
    defer text.deinit();
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "REFUSED 2 activation(s)") != null);
}
