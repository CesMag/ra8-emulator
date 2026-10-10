//! ra8_components: the parts outside the MCU that a board plugs onto the
//! chip's lines (ADR 0004 sections 2 and 3, knowledge base article
//! RA8EMU-A-2), one directory per part, with the plug layer at the root. It
//! imports only the chip's line contracts and the snapshot format. A part
//! that needs host data declares an interface, and the application fills it
//! from ra8_host.
pub const ov5640 = @import("camera_ov5640/ov5640_sccb.zig");
/// The camera part's frame production: host inputs wrapped and converted
/// to what the CEU programmed (RA8EMU-1059).
pub const camera = struct {
    pub const hosted = @import("camera_ov5640/hosted.zig");
    pub const converted = @import("camera_ov5640/converted_source.zig");
    pub const convert = @import("camera_ov5640/pixel_convert.zig");
};
pub const pi4ioe = @import("expander_pi4ioe/pi4ioe.zig");
pub const gt911 = @import("touch_gt911/gt911.zig");
pub const touch_input = @import("touch_gt911/touch_input.zig");
pub const user_switch = @import("user_switch/user_switch.zig");
pub const eth_phy = @import("eth_phy/phy.zig");
pub const eth_peer = @import("eth_phy/peer.zig");
pub const input_script = @import("touch_gt911/input_script.zig");
pub const lsm6dso = @import("imu_lsm6dso/lsm6dso.zig");
pub const max17048 = @import("gauge_max17048/max17048.zig");
pub const button = @import("button/button.zig");
pub const led = @import("led/led.zig");
pub const usb_echo = @import("usb_echo/device.zig");
pub const usb_echo_far = @import("usb_echo/far.zig");
pub const usb_loop_cable = @import("usb_loop_cable/cable.zig");
pub const usb_stick = @import("usb_stick/stick.zig");
pub const usb_stick_disk = @import("usb_stick/disk.zig");
pub const nor_flash = @import("nor_flash/flash.zig");
pub const modem_at = @import("modem_at/modem.zig");
pub const modem_at_script = @import("modem_at/script.zig");
pub const eink = @import("eink_it8951/panel.zig");
pub const eink_refresh = @import("eink_it8951/refresh.zig");
pub const eink_busy = @import("eink_it8951/busy.zig");
pub const eink_wire = @import("eink_it8951/wire.zig");
pub const eink_image = @import("eink_it8951/image.zig");
/// The plug layer: endpoints, the catalog, parts, requests and faults.
pub const model = @import("model.zig");
pub const sd_card = @import("sd_card/card.zig");
pub const sd_card_line = @import("sd_card/card_line.zig");
pub const sd_command = @import("sd_card/command.zig");
pub const sd_crc = @import("sd_card/crc.zig");
pub const sd_dump = @import("sd_card/dump.zig");
pub const sd_fat = @import("sd_card/fat.zig");
pub const sd_format = @import("sd_card/format.zig");
pub const sd_format_advice = @import("sd_card/format_advice.zig");
pub const sd_image = @import("sd_card/image.zig");
pub const sd_dirent = @import("sd_card/dirent.zig");
pub const sd_mkimage = @import("sd_card/mkimage.zig");
pub const sd_reply = @import("sd_card/reply.zig");
pub const sd_trace = @import("sd_card/trace.zig");
pub const sd_write = @import("sd_card/write.zig");
pub const sd_bus_card = @import("sd_card/bus_card.zig");
/// The ESP32-C6 on the EK-RA8D2, speaking esp-hosted over SPI or UART.
pub const esp_hosted = @import("esp32c6_hosted/esp_hosted.zig");
pub const sd_bus_line = @import("sd_card/bus_line.zig");
pub const c6_snapshot = @import("esp32c6_hosted/c6_snapshot.zig");
pub const card_snapshot = @import("sd_card/card_snapshot.zig");
pub const catalog = @import("catalog.zig");
pub const endpoint = @import("endpoint.zig");
pub const esp_tape = @import("esp32c6_hosted/esp_tape.zig");
pub const fault = @import("fault.zig");
pub const fault_lines = @import("fault_lines.zig");
pub const fault_schedule = @import("fault_schedule.zig");
pub const fault_spec = @import("fault_spec.zig");
pub const flash_snapshot = @import("nor_flash/flash_snapshot.zig");
pub const panel_snapshot = @import("eink_it8951/panel_snapshot.zig");
pub const parts = @import("parts.zig");
pub const request = @import("request.zig");
pub const stick_snapshot = @import("usb_stick/stick_snapshot.zig");
