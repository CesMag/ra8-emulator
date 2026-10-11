//! Session access to the board's RTC counters (RA8EMU-809): one snapshot
//! of the BCD registers the guest reads, taken without a bus access.
const Board = @import("ra8_board").board.Board;
const rtc = @import("ra8_chip").periph.rtc;
const session_rtc = @import("../rtc/rtc.zig");

/// The Clock hook over `board`'s RTC.
pub fn clock(board: *Board) session_rtc.Clock {
    return .{ .context = board, .countersFn = countersThunk };
}

fn countersThunk(context: *anyopaque) session_rtc.Counters {
    const board: *Board = @ptrCast(@alignCast(context));
    return counters(&board.clock);
}

/// The six calendar counters and the run state, read from the shadow.
pub fn counters(model: *const rtc.Rtc) session_rtc.Counters {
    const reg = &model.reg;
    return .{
        .second = reg[rtc.off.seccnt],
        .minute = reg[rtc.off.mincnt],
        .hour = reg[rtc.off.hrcnt],
        .day = reg[rtc.off.daycnt],
        .month = reg[rtc.off.moncnt],
        .year = reg[rtc.off.yrcnt],
        .running = model.running(),
    };
}
