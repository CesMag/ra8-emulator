//! Board time inside a debugger chunk (RA8EMU-1120). The board's clock
//! moves only at a boundary, so an event the core raises partway through a
//! chunk would read the time the chunk started at. A chunk as wide as a
//! plain run's stretch would stamp everything in it with one time; this
//! adds what CPU0 has retired since the board last ticked, one cycle per
//! instruction as the session's board time counts them.
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;

pub const ChunkClock = struct {
    cpu: ?*const Cpu = null,
    /// CPU0's retired count when the board last took a chunk.
    mark: u64 = 0,

    /// The board is about to take every instruction retired so far.
    pub fn handOver(self: *ChunkClock) void {
        const cpu = self.cpu orelse return;
        self.mark = cpu.retired;
    }

    /// Cycles CPU0 has run that the board has not been charged yet.
    pub fn ahead(self: *const ChunkClock) u64 {
        const cpu = self.cpu orelse return 0;
        return cpu.retired -| self.mark;
    }
};
