//! Stable device identity and credential initialization, independent of network.
const c = @import("csdk.zig");

pub fn init() bool {
    return c.sebastian_ensure_device_secret();
}

/// WiFi station MAC as twelve lowercase hexadecimal digits.
pub fn deviceId(out: *[13]u8) bool {
    var mac: [6]u8 = undefined;
    if (c.esp_read_mac(&mac, c.ESP_MAC_WIFI_STA) != c.ESP_OK) return false;
    const hex = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xF];
    }
    out[12] = 0;
    return true;
}
