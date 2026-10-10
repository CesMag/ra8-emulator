//! The interrupt controller's account of itself: what it routed, and the
//! external-IRQ pins it was told to reconfigure mid-flight.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;

pub fn sections(board: *Board, out: Writer) !void {
    try events(board, out);
    try pins(board, out);
}

/// The event links, but only once something raised an event. A re-pend is
/// reported loudly: it means a handler returned with IELSR.IR still set,
/// which on silicon re-enters that handler forever.
fn events(board: *Board, out: Writer) !void {
    if (board.events.quiet()) return;
    try out.print(
        "ICU: {d} event(s) raised, {d} line(s) pended, {d} unrouted",
        .{ board.events.raised, board.events.pends, board.events.unlinked },
    );
    if (board.events.repends != 0) {
        try out.print(", {d} RE-PENDED with IELSR.IR still latched", .{board.events.repends});
    }
    try out.print("\n", .{});
}

/// IRQCRa/IRQCRb. The loud line is a pin reconfigured while the controller
/// was still routing its event, which HUM Ch 14.2.12 p 535 says a firmware
/// may not do. The store landed here, because nothing written down says
/// what the part does with it; the count is the whole finding.
fn pins(board: *Board, out: Writer) !void {
    const unit = &board.events.pins;
    if (unit.quiet()) return;
    try out.print("ICU pins: {d} external IRQ pin(s) configured\n", .{unit.configured()});
    if (unit.rewrites_while_routed == 0) return;
    try out.print(
        "ICU pins: {d} REWRITE(S) of IRQCRi while that pin's event was still routed, unroute it first\n",
        .{unit.rewrites_while_routed},
    );
}
