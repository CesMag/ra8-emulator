//! The host adapter tests (src/host).
test {
    _ = @import("console_test.zig");
    _ = @import("read_test.zig");
    _ = @import("camera/pipe/windows_test.zig");
    _ = @import("camera/av/delegate_test.zig");
    _ = @import("camera/ppm_decode_test.zig");
    _ = @import("camera/bmp_decode_test.zig");
    _ = @import("camera/png_decode_test.zig");
    _ = @import("camera/image_file_test.zig");
    _ = @import("camera/video_file_test.zig");
    _ = @import("camera/pipe/input_test.zig");
    _ = @import("camera/pipe_record_test.zig");
    _ = @import("camera/webcam/input_test.zig");
    _ = @import("camera/webcam/open_test.zig");
    _ = @import("camera/av/webcam_test.zig");
    _ = @import("camera/mf/capture_test.zig");
    _ = @import("camera/mf/webcam_test.zig");
    _ = @import("camera/y4m/frame_test.zig");
    _ = @import("camera/pipe/frame_test.zig");
    _ = @import("camera/av/frame_test.zig");
    _ = @import("camera/source/spec_test.zig");
    _ = @import("camera/av/info_plist_test.zig");
    _ = @import("camera/av/objc_test.zig");
    _ = @import("camera/av/permission_test.zig");
    _ = @import("camera/av/session_test.zig");
    _ = @import("camera/mf/abi_test.zig");
    _ = @import("camera/mf/com_test.zig");
    _ = @import("camera/mf/open_test.zig");
    _ = @import("camera/v4l2/device_test.zig");
    _ = @import("camera/v4l2/negotiate_test.zig");
    _ = @import("camera/v4l2/stream_test.zig");
    _ = @import("camera/webcam/consent_test.zig");
    _ = @import("camera/webcam/always_test.zig");
    _ = @import("camera/webcam/privacy_test.zig");
    _ = @import("camera/y4m/header_test.zig");
}
