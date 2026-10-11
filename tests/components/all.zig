//! Tests for the parts outside the MCU: one directory per part, as in
//! src/components.

test {
    _ = @import("camera_ov5640/sccb_test.zig");
    _ = @import("camera_ov5640/pixel_convert_test.zig");
    _ = @import("camera_ov5640/converted_source_test.zig");
    _ = @import("camera_ov5640/hosted_test.zig");
    _ = @import("expander_pi4ioe/pi4ioe_test.zig");
    _ = @import("touch_gt911/gt911_test.zig");
    _ = @import("touch_gt911/input_script_test.zig");
    _ = @import("imu_lsm6dso/lsm6dso_test.zig");
    _ = @import("gauge_max17048/max17048_test.zig");
    _ = @import("usb/echo/device_test.zig");
    _ = @import("usb/loop_cable/cable_test.zig");
    _ = @import("usb/loop_cable/cable_bulk_test.zig");
    _ = @import("user_switch/user_switch_test.zig");
    _ = @import("eth_phy/phy_test.zig");
    _ = @import("eth_phy/peer_test.zig");
    _ = @import("usb/stick/stick_test.zig");
    _ = @import("usb/stick/disk_test.zig");
    _ = @import("nor_flash/flash_test.zig");
    _ = @import("sd_card/card/card_test.zig");
    _ = @import("sd_card/card/line_test.zig");
    _ = @import("sd_card/crc_test.zig");
    _ = @import("sd_card/dirent_test.zig");
    _ = @import("sd_card/dump_test.zig");
    _ = @import("sd_card/fat_test.zig");
    _ = @import("sd_card/format/format_test.zig");
    _ = @import("sd_card/image_test.zig");
    _ = @import("sd_card/mkimage_test.zig");
    _ = @import("sd_card/trace_test.zig");
    _ = @import("sd_card/write_test.zig");
    _ = @import("sd_card/bus/card_test.zig");
    _ = @import("sd_card/bus_card_image_test.zig");
    _ = @import("modem_at/modem_test.zig");
    _ = @import("modem_at/script_test.zig");
    _ = @import("eink_it8951/panel_test.zig");
    _ = @import("eink_it8951/busy_test.zig");
    _ = @import("eink_it8951/full_load_test.zig");
    _ = @import("eink_it8951/image_test.zig");
    _ = @import("eink_it8951/ghost_test.zig");
    _ = @import("eink_it8951/wire_test.zig");
    _ = @import("esp32c6_hosted/hosted_test.zig");
    _ = @import("plug/all.zig");
}
