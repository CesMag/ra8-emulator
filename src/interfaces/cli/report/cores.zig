//! The cross-core part of the end-of-run report: what went through the IPC
//! mailbox, what the other core was supposed to hear about, and what the
//! core's own MPU was asked to protect.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;
const ipc = @import("ra8_chip").periph.ipc;
const sync = @import("ra8_chip").periph.ipc_sync;
const ipc_attr = @import("ra8_chip").periph.ipc_attr;
const cpscu = @import("ra8_chip").periph.cpscu;
const cpu_ctrl = @import("ra8_chip").periph.cpu_ctrl;
const mpu = @import("ra8_chip").periph.mpu;
const sau = @import("ra8_chip").periph.sau;
const second_core = @import("ra8_chip").core.second_core;

/// What CPU0 did with the second-core release handshake. ACT going up means
/// the handshake completed, never by itself that a second core is fetching:
/// the release and the execution are two separate things and the lines are
/// never allowed to blur. Whether anything actually ran on CPU1 is the
/// second core's own line, printed by `cpu1` below, because
/// only the run knows whether an image was mapped onto it.
fn secondCore(board: *Board, out: Writer) !void {
    const unit = &board.second_core;
    if (unit.quiet()) return;
    try out.print(
        "CPU1: {s}, vector table 0x{X:0>8}, ACTCSR 0x{X:0>4}{s}\n",
        .{
            if (unit.act) "released" else "never activated",
            unit.initvtor,
            unit.status(),
            if (unit.running()) "" else ", CPUWAIT held",
        },
    );
    if (unit.act and !unit.mapped) {
        try out.print(
            "CPU1: released but no image was mapped onto it, so nothing ran there\n",
            .{},
        );
    }
    if (unit.refused != 0) {
        try out.print(
            "CPU1: DROPPED {d} ACTCSR store(s) whose key byte was not 0x{X:0>2}\n",
            .{ unit.refused, cpu_ctrl.key.value >> 8 },
        );
    }
}

/// What the firmware programmed into the MPU, and what enforcement made of
/// it. A store into a read-only region and a fetch out of an execute-never
/// one are both refused with a MemManage, so the violations are the line that
/// matters: a run that programmed a protected span and never tripped it is a
/// different run from one that did.
fn regions(board: *Board, out: Writer) !void {
    const unit = &board.regions;
    const latch = &board.guard.latch;
    if (!unit.on() and unit.programmed() == 0) return;
    try out.print(
        "MPU: {s}, {d} of {d} region(s) enabled, {d} read-only{s}\n",
        .{
            if (unit.on()) "enabled" else "programmed but never enabled",
            unit.programmed(),
            mpu.geometry.regions,
            unit.readOnly(),
            if (unit.privilegedDefault()) ", privileged default map on" else "",
        },
    );
    if (latch.violations != latch.fetches + latch.loads) {
        try out.print(
            "MPU: REFUSED {d} store(s) the region did not allow\n",
            .{latch.violations - latch.fetches - latch.loads},
        );
    }
    if (latch.loads != 0) {
        try out.print(
            "MPU: REFUSED {d} load(s) the region did not allow\n",
            .{latch.loads},
        );
    }
    if (latch.fetches != 0) {
        try out.print(
            "MPU: REFUSED {d} fetch(es) the region did not allow\n",
            .{latch.fetches},
        );
    }
    if (latch.background != 0) {
        try out.print(
            "MPU: {d} of those landed outside every region, with no default map\n",
            .{latch.background},
        );
    }
    if (latch.privilege != 0) {
        try out.print(
            "MPU: {d} of those were unprivileged, into a privileged-only region\n",
            .{latch.privilege},
        );
    }
    if (latch.violations != 0) {
        try out.print(
            "MPU: {d} of {d} violation(s) took MemManage\n",
            .{ latch.faults, latch.violations },
        );
    }
    if (latch.escalated != 0) {
        try out.print(
            "MPU: {d} of those escalated to HardFault, MemManage was never enabled\n",
            .{latch.escalated},
        );
    }
    if (latch.unhandled != 0) {
        try out.print(
            "MPU: {d} violation(s) with no MemManage handler to take them\n",
            .{latch.unhandled},
        );
    }
    if (latch.stood_down) {
        try out.print("MPU: enforcement stood down, a refused fetch had nowhere to go\n", .{});
    }
    if (unit.on() and latch.violations == 0) {
        try out.print(
            "MPU: {d} read-only region(s) enforced, no access was refused\n",
            .{unit.readOnly()},
        );
    }
}

/// One line per channel that carried anything, plus the losses. A message a
/// full FIFO dropped and a read that found nothing are both real failures of
/// the handshake, so they are reported apart from the traffic that worked.
/// What the firmware asked the SAU for. Worth its own line rather than
/// folding into the MPU's: the MPU says who may touch a span, the SAU says
/// which world the span belongs to, and a run that programmed one and not
/// the other is a run whose secure boot got part way. The line reports the
/// map and says plainly that this model keeps it without enforcing it, so
/// nobody reads the absence of a violation count as a clean bill of health.
fn partitions(board: *Board, out: Writer) !void {
    try partitionsOf(out, "SAU", &board.partitions);
}

/// The same lines for any core's SAU, under the name that core answers to.
/// Taken apart from `partitions` because the SAU is core-private: CPU1
/// carries one of its own (src/chip/core/second_core.zig), and its map is a
/// different map, not a second opinion about CPU0's.
pub fn partitionsOf(out: Writer, label: []const u8, unit: *const sau.Sau) !void {
    if (unit.quiet()) return;
    try out.print(
        "{s}: {s}, {d} of {d} region(s) enabled, {d} Non-Secure Callable{s}\n",
        .{
            label,
            if (unit.on()) "enabled" else "programmed but never enabled",
            unit.programmed(),
            sau.geometry.regions,
            unit.callable(),
            if (unit.outsideIsNonSecure()) ", outside every region is Non-Secure" else "",
        },
    );
    if (unit.refused != 0) {
        try out.print(
            "{s}: REFUSED {d} store(s) to the hardwired TYPE\n",
            .{ label, unit.refused },
        );
    }
}

/// Which IPC channels the Secure boot handed to the Non-Secure world, and
/// whether the words it wrote actually landed. A store made with PRC4 shut
/// is discarded by silicon, so it is reported as refused rather than folded
/// into the count: a firmware that forgot the unlock gave nothing away.
fn attribution(board: *Board, out: Writer) !void {
    const unit = &board.mailbox.attrib;
    if (unit.quiet()) return;
    try out.print(
        "IPC attribution: IPCSAR 0x{X:0>8}, IPCPAR 0x{X:0>8}, {d} of {d} channel(s) Non-Secure\n",
        .{ unit.sar, unit.par, unit.givenAway(), ipc_attr.field.channels },
    );
    if (unit.locked_writes != 0) {
        try out.print(
            "IPC attribution: REFUSED {d} store(s) with PRCR_S.PRC4 shut, the words never landed\n",
            .{unit.locked_writes},
        );
    }
}

/// What the Secure boot handed to the rest of the chip. Recorded, not
/// enforced: this board has no bus arbiter and no bus-initiator MPU, so the words
/// are reported and nothing is refused on the strength of them.
fn chipAttribution(board: *Board, out: Writer) !void {
    const unit = &board.chip_attribution;
    if (unit.quiet()) return;
    try out.print(
        "CPSCU attribution: BUSSAR 0x{X:0>8}/0x{X:0>8}/0x{X:0>8}, " ++
            "MMPUSAR 0x{X:0>8}/0x{X:0>8}, CPUSAR 0x{X:0>8}\n",
        .{
            unit.wordOf(.bussara),
            unit.wordOf(.bussarb),
            unit.wordOf(.bussarc),
            unit.wordOf(.mmpusara),
            unit.wordOf(.mmpusarb),
            unit.wordOf(.cpusar),
        },
    );
    if (unit.locked_writes != 0) {
        try out.print(
            "CPSCU attribution: REFUSED {d} store(s) with PRCR_S.PRC4 shut, the words never landed\n",
            .{unit.locked_writes},
        );
    }
    if (unit.reserved_writes != 0) {
        try out.print(
            "CPSCU attribution: {d} store(s) named an offset in the window that is not a register\n",
            .{unit.reserved_writes},
        );
    }
}

pub fn sections(board: *Board, out: Writer) !void {
    try secondCore(board, out);
    try regions(board, out);
    try partitions(board, out);
    try attribution(board, out);
    try chipAttribution(board, out);
    const mailbox = &board.mailbox;
    if (mailbox.quiet()) return;
    for (&mailbox.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "IPC ch{d}: {d} poke(s), {d} word(s) sent, {d} taken, STA 0x{X:0>8}\n",
            .{ index, unit.sends, unit.pushes, unit.pops, unit.status() },
        );
        if (unit.lost != 0) {
            try out.print(
                "IPC ch{d}: {d} message(s) LOST, the four stages were full\n",
                .{ index, unit.lost },
            );
        }
        if (unit.starved != 0) {
            try out.print(
                "IPC ch{d}: {d} read(s) with the FIFO empty, no message was there\n",
                .{ index, unit.starved },
            );
        }
        if (unit.narrow_reads != 0) {
            try out.print(
                "IPC ch{d}: REFUSED {d} load(s) of RXD narrower than a word, the stage was kept\n",
                .{ index, unit.narrow_reads },
            );
        }
        if (unit.narrow_writes != 0) {
            try out.print(
                "IPC ch{d}: REFUSED {d} store(s) to TXD narrower than a word, no part message was sent\n",
                .{ index, unit.narrow_writes },
            );
        }
    }
    if (mailbox.wakes != 0) {
        try out.print("IPC: {d} receive event(s) raised on this core\n", .{mailbox.wakes});
    }
    if (mailbox.undelivered != 0) {
        try out.print(
            "IPC: {d} poke(s) addressed to the secondary core, which this build does not run\n",
            .{mailbox.undelivered},
        );
    }
    try locks(&mailbox.locks, out);
}

/// The semaphore file and the two NMI doorbells. A lock still held at the end
/// of a run is the interesting one: the core that took it never gave it back,
/// and on a two-core part the other side is still spinning for it.
fn locks(unit: *const sync.Sync, out: Writer) !void {
    for (&unit.semaphores, 0..) |*one, index| {
        if (one.quiet()) continue;
        try out.print(
            "IPCSEM{d}: {d} taken, {d} contended, {d} released, {s}\n",
            .{
                index,
                one.takes,
                one.contentions,
                one.releases,
                if (one.locked) "STILL HELD" else "free",
            },
        );
        if (one.stray_releases != 0) {
            try out.print(
                "IPCSEM{d}: {d} release(s) of a lock nobody held\n",
                .{ index, one.stray_releases },
            );
        }
        if (one.unnamed_reads != 0) {
            try out.print(
                "IPCSEM{d}: {d} read(s) too narrow to carry LOCK, so they took nothing\n",
                .{ index, one.unnamed_reads },
            );
        }
    }
    for (&unit.doorbells, 0..) |*one, index| {
        if (one.quiet()) continue;
        try out.print(
            "IPC{d} NMI: {d} sent, {d} acknowledged, {s}\n",
            .{ index, one.sends, one.acks, if (one.pending) "PENDING" else "idle" },
        );
        if (one.coalesced != 0) {
            try out.print(
                "IPC{d} NMI: {d} send(s) onto a request already standing\n",
                .{ index, one.coalesced },
            );
        }
    }
}

/// What CPU1 did, printed under CPU0's own account of the run.
pub fn cpu1(out: Writer, second: ?*const second_core.Second) !void {
    const other = second orelse return;
    try out.print(
        "CPU1: loaded {d} bytes, vectors at 0x{X:0>8}, ran {d} instructions over {d} turn(s), pc 0x{X:0>8}\n",
        .{ other.state.written, other.state.vector_base, other.state.ran, other.state.turns, other.state.pc },
    );
    if (other.state.fault) |taken| {
        try out.print("CPU1: halted at 0x{X:0>8}: {s}\n", .{ taken.pc, taken.detail });
    }
    if (other.state.held) try out.writeAll("CPU1: held in reset since a system reset\n");
    // Silent on a core that never waited, which is every image in the
    // corpus today, so their reports stay as they were.
    if (other.state.wait.parks > 0) {
        const woke = other.state.wait.wakes;
        try out.print(
            "CPU1: parked in WFE {d} time(s), woken {d} by an exception, {d} by SEV, {d} spuriously\n",
            .{ other.state.wait.parks, woke.interrupt, woke.event, woke.spurious },
        );
    }
    // Under its own name, because this is a second map rather than more
    // detail about CPU0's. Silent on a core that never programmed one.
    try partitionsOf(out, "CPU1 SAU", &other.partitions);
}
