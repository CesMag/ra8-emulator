//! Where the `--dump-regs` rows of `--report json` read from (RA8EMU-579):
//! the Zig core's registers as the run left them.
const Cortex = @import("ra8_chip").core.cpu.cortex.Cortex;
const Regs = @import("ra8_chip").core.cpu.regs.Regs;

pub const Reader = union(enum) {
    zig: *const Regs,

    /// The register's value, or null when its source will not give it.
    pub fn register(self: Reader, which: Cortex) ?u32 {
        return switch (self) {
            .zig => |regs| fromRegs(regs, which),
        };
    }
};

/// The dumped registers out of the Zig core's file. SP is the active
/// stack pointer, the one the core's R13 names right now.
fn fromRegs(regs: *const Regs, which: Cortex) ?u32 {
    return switch (which) {
        .r0 => regs.get(0),
        .r1 => regs.get(1),
        .r2 => regs.get(2),
        .r3 => regs.get(3),
        .r4 => regs.get(4),
        .r5 => regs.get(5),
        .r6 => regs.get(6),
        .r7 => regs.get(7),
        .r8 => regs.get(8),
        .r9 => regs.get(9),
        .r10 => regs.get(10),
        .r11 => regs.get(11),
        .r12 => regs.get(12),
        .sp => regs.get(13),
        .lr => regs.lr,
        .pc => regs.pc,
        else => null,
    };
}
