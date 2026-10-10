//! The host adapter tests (src/host).
test {
    _ = @import("console_test.zig");
    _ = @import("read_test.zig");
    _ = @import("camera/pipe_windows_test.zig");
    _ = @import("camera/av_delegate_test.zig");
    _ = @import("camera/ppm_decode_test.zig");
    _ = @import("camera/bmp_decode_test.zig");
    _ = @import("camera/png_decode_test.zig");
    _ = @import("camera/image_file_test.zig");
    _ = @import("camera/video_file_test.zig");
    _ = @import("camera/pipe_input_test.zig");
    _ = @import("camera/webcam_input_test.zig");
    _ = @import("camera/webcam_open_test.zig");
    _ = @import("camera/av_webcam_test.zig");
    _ = @import("camera/mf_capture_test.zig");
    _ = @import("camera/mf_webcam_test.zig");
    _ = @import("camera/y4m_frame_test.zig");
    _ = @import("camera/pipe_frame_test.zig");
    _ = @import("camera/av_frame_test.zig");
    _ = @import("camera/source_spec_test.zig");
    _ = @import("camera/av_info_plist_test.zig");
    _ = @import("camera/av_objc_test.zig");
    _ = @import("camera/av_permission_test.zig");
    _ = @import("camera/av_session_test.zig");
    _ = @import("camera/mf_abi_test.zig");
    _ = @import("camera/mf_com_test.zig");
    _ = @import("camera/mf_open_test.zig");
    _ = @import("camera/v4l2_device_test.zig");
    _ = @import("camera/v4l2_negotiate_test.zig");
    _ = @import("camera/v4l2_stream_test.zig");
    _ = @import("camera/webcam_consent_test.zig");
    _ = @import("camera/webcam_privacy_test.zig");
    _ = @import("camera/y4m_header_test.zig");
}
