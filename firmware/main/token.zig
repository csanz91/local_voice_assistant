//! Fetch a conversation session from the complete provisioned endpoint URL.
const std = @import("std");
const c = @import("csdk.zig");
const identity = @import("identity.zig");
const log = std.log.scoped(.token);
var url_buf: [256]u8 = undefined;
var token_buf: [1280]u8 = undefined;
var endpoint: [256]u8 = undefined;
var secret_buf: [1025]u8 = undefined;
var room_buf: [128]u8 = undefined;
extern fn sebastian_session_create(endpoint: [*:0]const u8, device_id: [*:0]const u8, secret: [*:0]const u8, url: [*]u8, url_size: usize, token: [*]u8, token_size: usize, room: [*]u8, room_size: usize) c_int;
pub fn roomName() []const u8 {
    return std.mem.sliceTo(&room_buf, 0);
}
var id_z: [13]u8 = undefined;

pub const Connection = struct { server_url: [*:0]const u8, token: [*:0]const u8 };
pub const Error = error{ HttpFailed, Unprovisioned };

pub fn fetch() Error!Connection {
    if (!c.sebastian_get_token_url(&endpoint, endpoint.len) or
        !c.sebastian_get_device_secret(&secret_buf, secret_buf.len) or !identity.deviceId(&id_z))
        return error.Unprovisioned;
    const rc = sebastian_session_create(@ptrCast(&endpoint), @ptrCast(&id_z), @ptrCast(&secret_buf), &url_buf, url_buf.len, &token_buf, token_buf.len, &room_buf, room_buf.len);
    if (rc != 0) {
        log.err("session request failed (rc={d})", .{rc});
        return error.HttpFailed;
    }
    log.info("session created for device {s}", .{std.mem.sliceTo(&id_z, 0)});
    return .{ .server_url = @ptrCast(&url_buf), .token = @ptrCast(&token_buf) };
}

/// Experimental direct GPT-Live: the same provisioned endpoint and device
/// bearer; live_peer.c posts the SDP offer itself, so no fetch happens here.
pub const LiveCredentials = struct { endpoint: [*:0]const u8, secret: [*:0]const u8 };

pub fn liveCredentials() Error!LiveCredentials {
    if (!c.sebastian_get_token_url(&endpoint, endpoint.len) or
        !c.sebastian_get_device_secret(&secret_buf, secret_buf.len))
        return error.Unprovisioned;
    room_buf[0] = 0; // no LiveKit room on this path
    return .{ .endpoint = @ptrCast(&endpoint), .secret = @ptrCast(&secret_buf) };
}
