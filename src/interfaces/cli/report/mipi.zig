//! The MIPI D-PHY part of the end-of-run report.
//!
//! Its own file rather than a section inside graphics.zig, because the
//! PHY sits under both links: the DSI panel on one side and the CSI camera on
//! the other, and which one it was configured for is the first thing the line
//! says.
const std = @import("std");

const Board = @import("ra8_board").board.Board;

const Writer = *std.Io.Writer;

/// Quiet on a run that never touched the PHY, which is most of them. The
/// loud cases are a status read that found nothing latched, which is the
/// driver's own wait loop going nowhere, and a store to DPHYSFR, which is
/// firmware claiming a stability flag the PHY owns.
pub fn sections(board: *Board, out: Writer) !void {
    const phy = &board.link;
    if (phy.quiet()) return;
    try out.print(
        "MIPI-PHY: {s}, {s}, refclk {d} MHz, {d} power-up(s), {d} PLL lock(s)\n",
        .{
            phy.mode().name(),
            @import("ra8_chip").periph.mipi_phy_status.describe(phy.sfr()),
            phy.referenceMhz(),
            phy.powerups,
            phy.locks,
        },
    );
    if (phy.polls != 0 or phy.dark_polls != 0) {
        try out.print(
            "MIPI-PHY: {d} DPHYSFR read(s) found a flag up, {d} found nothing latched\n",
            .{ phy.polls, phy.dark_polls },
        );
    }
    if (phy.early_enables != 0) {
        try out.print(
            "MIPI-PHY: {d} of {d} lane enable(s) taken with DPHYSFR not ready, the link was started before the PHY said it was stable\n",
            .{ phy.early_enables, phy.enables },
        );
    }
    if (phy.pll.ignored != 0) {
        try out.print(
            "MIPI-PHY: IGNORED {d} DPHYPLFCR/DPHYESCCR store(s) made with the PLL running, the coefficients only latch while PLLSTP is set\n",
            .{phy.pll.ignored},
        );
    }
    if (phy.refused != 0) {
        try out.print(
            "MIPI-PHY: REFUSED {d} store(s) to DPHYSFR, firmware cannot raise its own stability flags\n",
            .{phy.refused},
        );
    }
}
