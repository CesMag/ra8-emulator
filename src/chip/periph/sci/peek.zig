//! What a debugger sees of a SCI channel (RA8EMU-949).
//!
//! A read of RDR takes the oldest queued byte, so a memory pane refreshing
//! over SCI would eat the characters the firmware has not read yet. A peek
//! shows that byte and leaves it queued. Every other word a read answers is
//! already computed from state and changes nothing (CSR, FRSR, FTSR, the
//! control words, the LIN registers), so a peek of those is the read.
const sci = @import("sci.zig");
const lanes = @import("../lanes.zig");

/// The registry's peek for the SCI block.
pub fn thunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *sci.Sci = @ptrCast(@alignCast(context));
    return peek(self, address, width);
}

pub fn peek(self: *sci.Sci, address: u32, width: u3) u32 {
    const offset = address -% sci.win_base;
    const index = offset / sci.stride;
    if (index >= sci.channels) return 0;
    const local = offset % sci.stride;
    if (lanes.word(local) != sci.off_rdr) return self.read(address, width);
    return lanes.part(data(&self.channels[index], lanes.lane(local)), lanes.lane(local), width);
}

/// RDR as a read would answer it, without the take: the oldest queued byte
/// for an access naming RDAT with the receiver on, zero otherwise.
fn data(channel: *const sci.Channel, at: u32) u32 {
    if (at != 0 or !channel.readable()) return 0;
    return channel.rx.first() orelse 0;
}
