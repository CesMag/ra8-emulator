//! What one SD_BUF0 access comes to: the data-phase rules, kept apart from
//! the register window in sdhi.zig the way dtc/xfer.zig and dmac/xfer.zig sit
//! beside their blocks. The window owns registers, flags and counters; this
//! owns whether a word moves at all and what the card does with a finished
//! block.
//!
//! THE CARD CAN REFUSE A BLOCK. The card behind `sdhi_line.Line` answers false for a block
//! off the end of it, and both sides of the FIFO used to throw that answer
//! away: a read staged zeros and raised BRE over them, and a write dropped
//! the block, walked the address on and cleared BWE at the end of the count.
//! Either way a driver was told a transfer it never got had finished. A
//! refused block now ENDS the phase: the blocks that landed stay landed, the
//! buffer flag comes down, and the run says how many blocks were lost.
//!
//! NOT MODELLED AND NOT GUESSED: the card status bit a real part sets for an
//! address off its end. The response registers here carry what the command
//! itself answered; nothing invents an error code the rest of the model does
//! not carry, so the only sign of a lost block is the flag that never comes
//! up and the report line at the end of the run.
const sd_line = @import("line.zig");
const xfer = @import("xfer.zig");

/// What an access did, in the window's terms.
pub const Outcome = enum {
    /// Narrower than the 32-bit port, so nothing moved.
    narrow,
    /// Nothing was armed behind the FIFO.
    starved,
    /// A word moved and the block it belongs to is still in flight.
    word,
    /// That word finished a block and the next one is in hand.
    block,
    /// That word finished the last block of the transfer.
    ended,
    /// The card refused the block, so the phase stopped where it stood.
    lost,
};

/// A word out of the FIFO, and what serving it came to.
pub const Read = struct {
    value: u32 = 0,
    outcome: Outcome,
};

/// Stage the block at the transfer's current address. A card that refuses it
/// stops the phase, so nothing is left armed over a block that never came.
pub fn load(transfer: *xfer.Transfer, disk: sd_line.Line) bool {
    if (disk.read(transfer.lba, &transfer.stage)) return true;
    transfer.stop();
    return false;
}

pub fn read(transfer: *xfer.Transfer, disk: sd_line.Line, width: u3) Read {
    if (width < 4) return .{ .outcome = .narrow };
    if (transfer.phase != .read) return .{ .outcome = .starved };
    const taken = transfer.pop();
    if (!taken.done) return .{ .value = taken.value, .outcome = .word };
    if (!transfer.advance()) return .{ .value = taken.value, .outcome = .ended };
    if (!load(transfer, disk)) return .{ .value = taken.value, .outcome = .lost };
    return .{ .value = taken.value, .outcome = .block };
}

pub fn write(transfer: *xfer.Transfer, disk: sd_line.Line, width: u3, value: u32) Outcome {
    if (width < 4) return .narrow;
    if (transfer.phase != .write) return .starved;
    if (!transfer.push(value)) return .word;
    if (!disk.write(transfer.lba, &transfer.stage)) {
        transfer.stop();
        return .lost;
    }
    if (transfer.advance()) return .block;
    return .ended;
}
