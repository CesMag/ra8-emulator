//! Wiring: the order the blocks go onto the peripheral bus.
//!
//! board.zig owns the blocks themselves, what each one is and how it is
//! built. This file owns the one thing that is not about any single block:
//! the sequence they are added in, which is load-bearing. The module-stop
//! shadow goes on first and then becomes the gate the rest of the bus is
//! filtered through; PORT follows it because PORT has no module-stop bit on
//! this part and has to answer regardless of MSTPCRx; and the blocks that
//! paint into or read out of RAM need guest memory handed to them as they go
//! on. Keeping it here leaves board.zig as the list of what the board is.
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const tsn_cal = @import("ra8_chip").periph.adc_tsn_cal;
const sau = @import("ra8_chip").periph.sau;
const mpu = @import("ra8_chip").periph.mpu;
const mpu_guard = @import("ra8_chip").core.mpu_guard;
const cpuid = @import("ra8_chip").periph.cpuid;
const dwt = @import("ra8_chip").periph.dwt;
const scb = @import("ra8_chip").periph.scb;
const fault_clear = @import("ra8_chip").periph.fault_clear;

const Board = @import("board.zig").Board;
const second_wiring = @import("ra8_chip").core.second_wiring;
const plug = @import("plug.zig");

const bkup = @import("ra8_chip").periph.bkup;
const dmac = @import("ra8_chip").periph.dmac;
const drw = @import("ra8_chip").periph.drw;
const eink = @import("../components/eink_it8951/panel.zig");
const modem = @import("../components/modem_at/modem.zig");
const ckcr = @import("ra8_chip").periph.ckcr;
const octaclk = @import("ra8_chip").periph.octaclk;
const mrms = @import("ra8_chip").periph.mrms;
const ckdiv = @import("ra8_chip").periph.ckdiv;
const oscsf = @import("ra8_chip").periph.oscsf;
const subclock = @import("ra8_chip").periph.subclock;
const reset = @import("ra8_chip").periph.reset;
const sysclk = @import("ra8_chip").periph.sysclk;
const voltage_hazard = @import("ra8_chip").periph.voltage_hazard;
const lpm = @import("ra8_chip").periph.lpm;
const pll = @import("ra8_chip").periph.pll;
const gtclkcr = @import("ra8_chip").periph.gtclkcr;
const pscu = @import("ra8_chip").periph.pscu;
const cpscu = @import("ra8_chip").periph.cpscu;
const dtc = @import("ra8_chip").periph.dtc;
const vscr = @import("ra8_chip").periph.vscr;
const pdctr = @import("ra8_chip").periph.pdctr;
const sd_card = @import("../components/sd_card/card.zig");
const sd_card_line = @import("../components/sd_card/card_line.zig");
const bus_line = @import("../components/sd_card/bus_line.zig");

/// The module-stop shadow, the attribution words that decide which of its
/// bits a Secure store may move, and the gate the rest of the bus hangs off.
/// These three go on together because none of them is any use alone.
fn attachGate(self: *Board) !void {
    try self.bus.add(self.modules.block());
    self.modules.attribution = &self.attribution;
    self.modules.bus = &self.bus;
    try self.bus.add(self.attribution.block());
    self.bus.gate = self.modules.gate();
}

/// The ADC, and the TSN factory calibration words its die-temperature line
/// is converted against (adc_tsn_cal.zig).
fn attachAdc(self: *Board, core: Guest) !void {
    try self.bus.add(self.adc.block());
    _ = tsn_cal.map(core) catch false;
}

/// The CEU, with the memory its frames land in and the virtual time its
/// camera source reads at each arm (RA8EMU-540).
fn attachCapture(self: *Board, memory: Guest) !void {
    self.capture.memory = memory;
    self.capture.clock = &self.time.base;
    try self.bus.add(self.capture.block());
}

/// The I2C lines with their fitted parts, then the run's `--attach` asks,
/// so a clash with a fitted part is reported against the ask.
fn attachWire(self: *Board) !void {
    try self.wire.attach(&self.bus);
    self.wire.clock(&self.time.base);
    try plug.all(self);
}

/// Every block onto the bus, in the order that works. The blocks that
/// paint or read RAM get `memory`: the Zig core's store, whose own PPB
/// windows `primeWindows` seeds.
pub fn attachBlocks(self: *Board, memory: Guest) !void {
    try attachGate(self);
    try self.bus.add(self.pins.block());
    try self.bus.add(self.pinfunc.block());
    try self.bus.add(self.checksum.block());
    try self.bus.add(self.dataops.block());
    try self.bus.add(self.accuracy.block());
    try self.bus.add(self.comparators.block());
    try attachCapture(self, memory);
    try self.bus.add(self.analog.block());
    try attachAdc(self, memory);
    try self.bus.add(self.shutoff.block());
    try self.bus.add(self.protection.block());
    try attachProtected(self);
    // The panel is scanned out of the same RAM the core paints into.
    try self.display.attach(&self.bus, &self.domains.graphics, memory);
    self.raster = drw.Drw.init(&self.domains.graphics);
    // Rendering uses the board's RAM.
    self.raster.memory = memory;
    try self.bus.add(self.raster.block());
    try self.bus.add(self.link.block());
    try self.bus.add(self.receiver.block());
    try self.bus.add(self.host.block());
    try self.bus.add(self.serial.block());
    try self.bus.add(self.spi.block());
    // The card is on Pmod2, which is SCI0 in Simple-SPI mode, not on a
    // SPI_B channel (src/components/sd_card/card_line.zig).
    self.sd_line = sd_card_line.Line.init(&self.sd);
    self.serial.attachDevice(sd_card_line.line_channel, self.sd_line.device());
    self.spi.attachDevice(eink.line_channel, self.panel.device());
    self.pins.setInput(eink.hrdy.port, eink.hrdy.pin, true);
    self.serial.attachDevice(modem.line_channel, self.modem.device());
    try attachWire(self);
    try self.rswitch.attach(&self.bus, memory, &self.domains.eswm);
    try self.usb.attach(&self.bus);
    self.trace.memory = memory;
    try self.bus.add(self.flash.block());
    try self.bus.add(self.cipher.block());
    try self.options.attach(&self.bus, memory);
    try self.bus.add(self.second_core.block());
    try self.bus.add(self.memory_rates.block());
    try self.memory_ecc.attach(&self.bus);
    try self.sdram.attach(&self.bus);
    self.card.card = bus_line.line(&self.host_card);
    try self.bus.add(self.card.block());
    try self.bus.add(self.ecc.block());
    try self.bus.add(self.audio.block());
    try self.bus.add(self.microphone.block());
    try self.bus.add(self.clock.block());
    try self.bus.add(self.can.block(0));
    try self.bus.add(self.can.block(1));
    try self.bus.add(self.mailbox.block());
    if (self.part.hasNpu()) {
        self.npu.memory = memory.asInitiator(.ethos_u55);
        try self.bus.add(self.npu.block());
    }
    try self.bus.add(self.lowpower.block());
    try self.bus.add(self.interval.block());
    try self.bus.add(self.pwm.block());
    try self.bus.add(self.ptp.block());
    self.events.issuer = &self.bus.issuer;
    try self.bus.add(self.events.block());
    try self.bus.add(self.events.pinsBlock());
    for (self.events.sideBlocks()) |block| try self.bus.add(block);
    try self.bus.add(self.links.block());
    try attachTransfers(self);
    try self.bus.add(self.dma_module.block());
    self.dma = dmac.Dmac.init(&self.dma_module);
    self.dma.memory = memory;
    try self.bus.add(self.dma.block());
    try self.bus.add(self.monitors.statusBlock());
    try self.bus.add(self.monitors.controlBlock());
    try self.bus.add(self.monitors.filterBlock());
    try self.bus.add(self.watchdog.block());
    try self.bus.add(self.heartbeat.block());
    try self.bus.add(self.causes.statusBlock());
    try self.bus.add(self.causes.causeBlock());
}

/// DTC0 and DTC1 share one window, served by whichever core is on the bus;
/// DTC1 starts on the DTCE bits of CPU1's ICU table.
fn attachTransfers(self: *Board) !void {
    self.transfers1.table = .cpu1;
    self.transfers.twin = &self.transfers1;
    self.transfers.issuer = &self.bus.issuer;
    try self.bus.add(self.transfers.block());
    self.transfer_attribution = dtc.attribution.Unit.init(&self.protection);
    try self.bus.add(self.transfer_attribution.block());
}

/// CPU0's windows: the board's own SAU, MPU tables, guard, AIRCR and
/// fault clears. A `--cpu zig` run primes them into its own store.
pub fn cpu0Windows(self: *Board) CoreWindows {
    return .{
        .partitions = &self.partitions,
        .regions = &self.regions,
        .regions_ns = &self.regions_ns,
        .guard = &self.guard,
        .identity = cpuid.cpu0,
        .control = &self.control,
        .clears = &self.clears,
    };
}

/// The windows a core keeps to itself, declared by the chip (RA8EMU-1012).
pub const CoreWindows = @import("ra8_chip").core.core_windows.CoreWindows;

/// The wiring CPU1's bring-up takes from this board (RA8EMU-1012). The chip
/// owns bring-up; the board supplies its bus, divider, reboot latch,
/// release page and event slot, and primes and resets on CPU1's behalf.
pub fn cpu1(self: *Board) second_wiring.Wiring {
    return .{
        .bus = &self.bus,
        .dividers = &self.tree.divcr2,
        .reboot = &self.reboot,
        .release = &self.second_core,
        .cpu1 = &self.cpu1,
        .context = self,
        .primeFn = primeThunk,
        .resetFn = resetThunk,
    };
}

fn primeThunk(context: *anyopaque, memory: Guest, windows: CoreWindows) anyerror!void {
    const self: *Board = @ptrCast(@alignCast(context));
    return primeWindows(self, memory, windows);
}

fn resetThunk(context: *anyopaque) void {
    const self: *Board = @ptrCast(@alignCast(context));
    self.requestResetFrom(.software, .cpu1);
}

/// The core's own windows are PPB RAM rather than bus blocks, and RAM starts
/// at zero. Every one of these is a register the firmware reads before it
/// writes anything, so a zero is not a neutral starting value: it is a wrong
/// answer the firmware then believes. Seed each with what the core reports.
/// The windows that live inside a core rather than on the bus, seeded and
/// hooked for the core in front of them.
///
/// `partitions` is the caller's because the SAU is CORE-PRIVATE STATE: each
/// Cortex-M has its own, reached through its own PPB, and two cores
/// programme two different maps. Sharing one model let CPU1's SAU
/// bring-up land on top of CPU0's, and the report then described neither
/// core: with `cpu1_pingpong_ipc` mapped onto CPU1, CPU0's five regions and
/// two Non-Secure Callable entries read back as five regions and none,
/// because CPU1 had overwritten the first four with its own.
///
/// THE MPU BESIDE IT IS CORE-PRIVATE IN EXACTLY THE SAME WAY, so it comes
/// in with the SAU: the table and the guard that enforces it are the
/// caller's. Shared, a CTRL store from either core rebuilt the traps from
/// one table on whichever core made it, and CPU0's regions were CPU1's.
///
/// The reset values a core's own PPB windows read as, written into
/// `memory` (RA8EMU-550).
pub fn primeWindows(self: *Board, memory: Guest, windows: CoreWindows) !void {
    // CPUID read as zero on both cores, so neither said what it was.
    try cpuid.prime(memory, windows.identity);
    // DWT_CTRL.NUMCOMP read as zero, so the core claimed no comparators.
    try memory.writeWord(dwt.base, dwt.ctrlReset(windows.identity));
    // AIRCR: the first read of it is 0 rather than the key status.
    try windows.control.prime(memory);
    // CTR read as zero, so the firmware computed a four-byte line and
    // walked every range eight times over.
    try self.caches.prime(memory);
    // MPU_TYPE read as zero, so ra8_mpu_configure rejected every
    // configuration for want of capacity and main never got past it.
    try windows.regions.prime(memory);
    // The Non-secure view of MPU_TYPE is its own banked word (RA8EMU-446).
    try mpu.ns.prime(memory, mpu.geometry.type_value);
    // SAU_TYPE read as zero, so the secure boot's capability check failed
    // and ra8_tz_secure_boot_sau_init programmed nothing and returned an
    // error, parking the run in the Secure fallback main() forever.
    try windows.partitions.prime(memory);
}

/// The blocks that ask PRCR before they accept a store. Each needs a pointer
/// to the protection model this board owns, not a copy of one, so none of
/// them can be built in the struct literal.
fn attachProtected(self: *Board) !void {
    self.backup = bkup.Bkup.init(&self.protection);
    try self.bus.add(self.backup.block());
    self.battery_switch = bkup.pcr1.Pcr1.init(&self.protection);
    try self.bus.add(self.battery_switch.block());
    self.oscillators = oscsf.Oscillators.init(&self.protection);
    try self.bus.add(self.oscillators.block());
    self.subclk = subclock.Unit.init(&self.protection);
    try self.bus.add(self.subclk.block());
    self.loco = subclock.loco.Unit.init(&self.protection);
    try self.bus.add(self.loco.block());
    // The tree asks the oscillators whether the source it was told to select
    // had stabilised, so it goes on after them.
    // The core voltage range is step 2 of the same protected bring-up, and it
    // has to exist before the tree: the tree tells the brown-out watch about
    // every clock select, and the watch reads this range live.
    self.voltage = vscr.Unit.init(&self.protection);
    try self.bus.add(self.voltage.block());
    self.brownout = voltage_hazard.Watch.init(&self.voltage);
    self.tree = sysclk.Tree.init(&self.protection, &self.oscillators, &self.brownout);
    try self.bus.add(self.tree.block());
    self.branches = ckcr.Ckcr.init(&self.protection);
    for (0..ckcr.windows.len) |which| try self.bus.add(self.branches.block(which));
    // MSTPB16/B17 may only be released once OCTACKCR has handshaken (HUM
    // Ch 11.2.7 Note 3), so the watch reads the selects live and both the
    // module-stop window and the command engine it uncovers consult it.
    self.octa = octaclk.Octa.init(&self.branches);
    self.modules.octa = &self.octa;
    self.flash.octa = &self.octa;
    self.flash.part = self.nor.nor();
    // The dividers ask the selects whether the branch is gated, so they go
    // on after the selects they are paired with.
    self.ratios = ckdiv.Ckdiv.init(&self.protection, &self.branches);
    for (0..ckdiv.windows.len) |which| try self.bus.add(self.ratios.block(which));
    // PLL1's configuration asks PRCR before a store, as the clock tree does.
    self.plls = pll.Unit.init(&self.protection, &self.oscillators);
    // GTCLKCR is the GPT bank's clock domain, and only the module-stop
    // model can say whether the window to change it is still open.
    self.gpt_clock = gtclkcr.Unit.init(&self.modules);
    try self.bus.add(self.gpt_clock.block());
    try self.bus.add(self.pwm_delay.block());
    for (0..pll.slots.len) |which| try self.bus.add(self.plls.block(which));
    // The low-power bytes ask PRCR before a store, so they go on after it.
    self.low_power = lpm.Unit.init(&self.protection);
    for (0..lpm.slots.len) |which| try self.bus.add(self.low_power.block(which));
    try self.bus.add(self.standby_cancel.block());
    self.domains = pdctr.Domains.init(&self.protection);
    try self.bus.add(self.domains.graphics.block());
    try self.bus.add(self.domains.eswm.block());
    // SYRSTMSK0/1/2 is PRC5-protected, and its two watchdog mask bits freeze
    // while their watchdog runs (HUM Ch 6.2.6 p 263), so it reads both
    // watchdogs' armed flags live rather than a copy.
    self.causes.watchWatchdogs(
        &self.protection,
        &self.watchdog.armed,
        &self.heartbeat.armed,
    );
    try self.bus.add(self.causes.maskBlock());
    // IPCSAR / IPCPAR are PRC4-gated and sit in CPSCU, nowhere near the
    // mailbox window, so the mailbox offers them as a block of their own.
    self.mailbox.protect(&self.protection);
    try self.bus.add(self.mailbox.attributionBlock());
    // The rest of the CPSCU attribution the boot writes in the same scope:
    // the bus initiators, the bus-initiator MPUs and the second CPU, behind PRC4 too.
    self.chip_attribution = cpscu.Unit.init(&self.protection);
    try self.bus.add(self.chip_attribution.block());
    for (self.sram_attribution.blocks()) |window| try self.bus.add(window);
    self.idau = sau.idau.Map.forPart(&self.sram_attribution, self.part == .ra8p1);
    for (self.memory_monitors.blocks()) |window| try self.bus.add(window);
    if (self.memory_monitors.cms) |area| self.idau.code_secure = sau.idau.cmsBytes(area);
}
