//! Which IPC reads may be repeated without being stepped (RA8EMU-602).
//!
//! A channel's STA is composed from the ring and the error latches on every
//! read and changes nothing, so a repeat of it reads the same word until a
//! store lands. Within one stretch nothing stores: the other core is not
//! running, and a store by this core spoils the watched trip anyway. RXD
//! pops a stage and never repeats; ISET, TXD and CLR are actions; the
//! padding inside a window is shadow nobody polls. The semaphore and NMI
//! region below the windows answers through ipc_sync.
const ipc = @import("ipc.zig");
const lanes = @import("../lanes.zig");

/// Whether `times` more reads of `offset` would each answer what the last
/// one did; when so, anything they would count is counted. Times 0 asks.
pub fn repeat(unit: *ipc.Ipc, offset: u32, width: u3, times: u64) bool {
    if (offset >= ipc.win_span) return false;
    if (offset < ipc.ch0_offset) {
        return unit.locks.repeat(offset, lanes.named(offset % 4, width), times);
    }
    const relative = offset - ipc.ch0_offset;
    if (relative / ipc.ch_stride >= ipc.ch_count) return false;
    return relative % ipc.ch_stride & ~@as(u32, 3) == ipc.off_sta;
}
