//! ra8_components: the parts outside the MCU that a board plugs onto the
//! chip's lines (ADR 0004 sections 2 and 3, knowledge base article
//! RA8EMU-A-2), one directory per part, with the plug layer at the root. It
//! imports only the chip's line contracts and the snapshot format. A part
//! that needs host data declares an interface, and the application fills it
//! from ra8_host.
pub const ov5640 = @import("camera_ov5640/sccb.zig");
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
pub const usb_loop_cable = @import("usb_loop_cable/cable.zig");
pub const usb_stick = @import("usb_stick/stick.zig");
pub const nor_flash = @import("nor_flash/flash.zig");
pub const modem_at = @import("modem_at/modem.zig");
pub const eink = @import("eink_it8951/panel.zig");
/// The plug layer: endpoints, the catalog, parts, requests and faults.
pub const model = @import("model.zig");
pub const sd_card = @import("sd_card/card.zig");
/// The ESP32-C6 on the EK-RA8D2, speaking esp-hosted over SPI or UART.
pub const esp_hosted = @import("esp32c6_hosted/hosted.zig");
pub const catalog = @import("catalog.zig");
pub const endpoint = @import("endpoint.zig");
pub const esp_tape = @import("esp32c6_hosted/tape.zig");
pub const fault = @import("fault.zig");
pub const fault_lines = @import("fault_lines.zig");
pub const fault_schedule = @import("fault_schedule.zig");
pub const fault_spec = @import("fault_spec.zig");
pub const parts = @import("parts.zig");
pub const request = @import("request.zig");
