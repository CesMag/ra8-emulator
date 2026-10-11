//! The initial value of every block the board holds.
//!
//! board.zig is the list of what a board is made of, and wiring.zig is the
//! order those blocks go onto the bus. This file is the third question and
//! the least interesting one: what each block starts as before anything has
//! been wired or run. It is here rather than in board.zig because the list
//! of parts and the construction of them are two subjects, and the list is
//! the one worth reading first.
//!
//! A field left `undefined` here is one that cannot exist yet: it needs a
//! pointer into the board that is still being built, so wiring.zig fills it
//! in during attach(). The comment on the field in board.zig says which.
const std = @import("std");

const Board = @import("board.zig").Board;

const periph = @import("ra8_chip").periph.registry;
const acmphs = @import("ra8_chip").periph.acmphs;
const adc = @import("ra8_chip").periph.adc;
const agt = @import("ra8_chip").periph.agt;
const cac = @import("ra8_chip").periph.cac;
const cache = @import("ra8_chip").periph.cache;
const canfd = @import("ra8_chip").periph.canfd;
const ceu = @import("ra8_chip").periph.ceu;
const crc = @import("ra8_chip").periph.crc;
const dac = @import("ra8_chip").periph.dac;
const doc = @import("ra8_chip").periph.doc;
const dotf = @import("ra8_chip").periph.dotf;
const dtc = @import("ra8_chip").periph.dtc;
const elc = @import("ra8_chip").periph.elc;
const gpio = @import("ra8_chip").periph.gpio;
const switches = @import("switches.zig");
const gpt = @import("ra8_chip").periph.gpt;
const gptp = @import("ra8_chip").periph.gptp;
const icu = @import("ra8_chip").periph.icu;
const ipc = @import("ra8_chip").periph.ipc;
const iwdt = @import("ra8_chip").periph.iwdt;
const lvd = @import("ra8_chip").periph.lvd;
const mipi_csi = @import("ra8_chip").periph.mipi.csi;
const mipi_dsi = @import("ra8_chip").periph.mipi.dsi;
const mipi_phy = @import("ra8_chip").periph.mipi.phy;
const mpu = @import("ra8_chip").periph.mpu;
const mpu_guard = @import("ra8_chip").core.mpu_guard;
const mram = @import("ra8_chip").periph.mram;
const npu = @import("ra8_chip").periph.npu;
const pdm = @import("ra8_chip").periph.pdm;
const pfs = @import("ra8_chip").periph.pfs;
const poeg = @import("ra8_chip").periph.poeg;
const prcr = @import("ra8_chip").periph.prcr;
const reset = @import("ra8_chip").periph.reset;
const rtc = @import("ra8_chip").periph.rtc;
const sau = @import("ra8_chip").periph.sau;
const scb = @import("ra8_chip").periph.scb;
const fault_clear = @import("ra8_chip").periph.fault.clear;
const sci = @import("ra8_chip").periph.sci;
const sd_card = @import("ra8_components").sd_card;
const bus_card = @import("ra8_components").sd_card.bus_card;
const sdhi = @import("ra8_chip").periph.sdhi;
const spi = @import("ra8_chip").periph.spi;
const sram = @import("ra8_chip").periph.sram;
const ssie = @import("ra8_chip").periph.ssie;
const ulpt = @import("ra8_chip").periph.ulpt;
const wdt = @import("ra8_chip").periph.wdt;
const xspi = @import("ra8_chip").periph.xspi;
const nor_flash = @import("ra8_components").nor_flash;

/// A fresh board, with nothing on the bus yet.
pub fn build(allocator: std.mem.Allocator) Board {
    return .{
        .bus = periph.Bus.init(allocator),
        .events = icu.Icu.init(),
        .links = elc.Elc.init(),
        .transfers = dtc.Dtc.init(),
        .transfers1 = dtc.Dtc.init(),
        .transfer_attribution = undefined,
        .dma = undefined,
        .pins = switches.pulled(),
        .touch_input = .{ .switches = &switches.user },
        .pinfunc = pfs.Pfs.init(),
        .checksum = crc.Crc.init(),
        .dataops = doc.Doc.init(),
        .accuracy = cac.Cac.init(),
        .comparators = acmphs.Acmphs.init(),
        .capture = ceu.Ceu.init(),
        .analog = dac.Dac.init(),
        .adc = adc.Adc.init(),
        .shutoff = poeg.Poeg.init(),
        .protection = prcr.Prcr.init(),
        // Patched in attach(): the backup file has to point at this
        // board's own protection model, not a copy of it.
        .backup = undefined,
        .battery_switch = undefined,
        .oscillators = undefined,
        .subclk = undefined,
        .loco = undefined,
        .tree = undefined,
        .low_power = undefined,
        .plls = undefined,
        .gpt_clock = undefined,
        .voltage = undefined,
        .brownout = undefined,
        .ratios = undefined,
        .branches = undefined,
        .chip_attribution = undefined,
        .domains = undefined,
        .display = undefined,
        .raster = undefined,
        .serial = sci.Sci.init(),
        .spi = spi.Spi.init(),
        .sd = sd_card.Card.init(allocator),
        .flash = .{},
        .nor = nor_flash.Flash.init(allocator),
        .octa = undefined,
        .cipher = dotf.Dotf.init(),
        .card = sdhi.Sdhi.init(),
        .host_card = bus_card.Card.init(allocator),
        .options = mram.Mram.init(allocator),
        .ecc = sram.Sram.init(),
        .audio = ssie.Ssie.init(),
        .microphone = pdm.Pdm.init(),
        .clock = rtc.Rtc.init(),
        .can = canfd.Canfd.init(),
        .mailbox = ipc.Ipc.init(),
        .npu = npu.Npu.init(),
        .lowpower = ulpt.Ulpt.init(),
        .interval = agt.Agt.init(),
        .pwm = gpt.Gpt.init(),
        .pwm_delay = gpt.pdg.Pdg.init(),
        .ptp = gptp.Gptp.init(),
        .monitors = lvd.Lvd.init(),
        .watchdog = wdt.Wdt.init(),
        .heartbeat = iwdt.Iwdt.init(),
        .link = mipi_phy.MipiPhy.init(),
        .receiver = mipi_csi.MipiCsi.init(),
        .host = mipi_dsi.MipiDsi.init(),
        .causes = reset.Reset.init(),
        .control = scb.Scb.init(),
        .clears = fault_clear.Clears.init(),
        .caches = cache.Cache.init(),
        .regions = mpu.Mpu.init(),
        .regions_ns = mpu.Mpu.init(),
        .guard = mpu_guard.Guard.init(),
        .partitions = sau.Sau.init(),
    };
}
