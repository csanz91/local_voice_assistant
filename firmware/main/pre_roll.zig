//! Local pre-roll buffer captured before LiveKit connects.
//!
//! In IDLE the wake word task owns I2S, so this module is fed from
//! wakeword.zig, not mic_src.zig. Nothing leaves the device until a wake word
//! fires and the room is connected.

const std = @import("std");
const c = @import("csdk.zig");
const core = @import("core/pre_roll_core.zig");

const log = std.log.scoped(.pre_roll);

pub const SAMPLE_RATE = core.SAMPLE_RATE;
pub const SECONDS = core.SECONDS;
pub const SAMPLE_CAPACITY = core.SAMPLE_CAPACITY;

const TOPIC = "lk.agent.pre-connect-audio-buffer";

var ring: ?[*]i16 = null;
var write_idx: usize = 0;
var filled: usize = 0;
var total_written: u64 = 0;
var wake_mark: ?u64 = null;

/// The ring is always full (the wake task feeds it from boot), so the SEND
/// window is anchored to the wake mark: this much audio before the wake word,
/// plus everything after it up to the handoff. Without the anchor we'd ship
/// 12s of stale room noise ahead of the request every session.
pub const WAKE_LEAD_SAMPLES: usize = SAMPLE_RATE * 2;

pub fn init() bool {
    if (ring != null) return true;

    const bytes = SAMPLE_CAPACITY * @sizeOf(i16);
    const mem = c.heap_caps_malloc(bytes, c.MALLOC_CAP_SPIRAM | c.MALLOC_CAP_8BIT) orelse {
        log.err("PSRAM allocation failed ({d} bytes)", .{bytes});
        return false;
    };
    ring = @ptrCast(@alignCast(mem));
    reset();
    log.info("allocated {d} ms local pre-roll ({d} bytes)", .{ SECONDS * 1000, bytes });
    return true;
}

pub fn reset() void {
    write_idx = 0;
    filled = 0;
    total_written = 0;
    wake_mark = null;
}

pub fn feed(samples: []const i16) void {
    const buf = ring orelse return;
    const n = core.writableSamples(wake_mark, total_written, samples.len);
    for (samples[0..n]) |sample| {
        buf[write_idx] = sample;
        write_idx = (write_idx + 1) % SAMPLE_CAPACITY;
        if (filled < SAMPLE_CAPACITY) filled += 1;
    }
    total_written += n;
}

/// Called by the wake task at the detection instant.
pub fn markWake() void {
    wake_mark = total_written;
}

fn windowSamples() usize {
    return core.windowSamples(wake_mark orelse 0, total_written, filled);
}

pub fn availableMs() u32 {
    return core.availableMs(windowSamples());
}

fn writeSamples(room: c.livekit_room_handle_t, stream: c.livekit_data_stream_handle_t, start: usize, count: usize) bool {
    if (count == 0) return true;
    const buf = ring orelse return false;
    const slice = buf[start .. start + count];
    const bytes: [*]const u8 = @ptrCast(slice.ptr);
    return c.livekit_room_data_stream_write(room, stream, bytes, slice.len * @sizeOf(i16)) == c.LIVEKIT_ERR_NONE;
}

pub fn send(room: c.livekit_room_handle_t, wake_id: u32, track_sid: [*:0]const u8, confirm_batch: *const fn (u32, i64) bool) bool {
    const count = windowSamples();
    if (ring == null or count == 0) {
        log.warn("no pre-roll available for wake_id={d}", .{wake_id});
        return false;
    }

    const sample_count: u32 = @intCast(count);
    const total_len: u64 = @as(u64, sample_count) * @sizeOf(i16);
    const attrs = [_]c.livekit_attribute_t{
        .{ .key = "trackId", .value = track_sid },
        .{ .key = "sampleRate", .value = "16000" },
        .{ .key = "channels", .value = "1" },
    };
    var opts = c.livekit_data_stream_options_t{
        .attributes = &attrs,
        .attributes_count = attrs.len,
        .topic = TOPIC,
        .is_text = false,
        // No declared total: a deadline-truncated send still ends as a valid,
        // shorter stream that RoomIO delivers, instead of a length mismatch.
        .total_length = 0,
        .has_total_length = false,
    };
    var stream: c.livekit_data_stream_handle_t = null;
    if (c.livekit_room_data_stream_open(room, &opts, &stream) != c.LIVEKIT_ERR_NONE or stream == null) {
        log.err("open data stream failed for wake_id={d}", .{wake_id});
        return false;
    }

    var ok = true;

    var pos = core.startIndex(write_idx, count);
    var remaining = count;
    var batch: u32 = 0;
    var sent: usize = 0;
    // Inside RoomIO's 3 s budget from stream open (pre_connect_audio_timeout).
    const started_us = c.esp_timer_get_time();
    const deadline = started_us + 2_500_000;
    while (remaining > 0) {
        const n = @min(remaining, core.BATCH_SAMPLES);
        const first = @min(n, SAMPLE_CAPACITY - pos);
        if (!writeSamples(room, stream, pos, first) or !writeSamples(room, stream, 0, n - first)) {
            ok = false;
            break;
        }
        remaining -= n;
        sent += n;
        pos = (pos + n) % SAMPLE_CAPACITY;
        batch += 1;
        if (remaining != 0 and !confirm_batch(batch, deadline)) {
            ok = false;
            break;
        }
    }

    // Close unconditionally — skipping it on a failed write leaks the handle.
    const closed = c.livekit_room_data_stream_close(room, stream) == c.LIVEKIT_ERR_NONE;
    ok = ok and closed;
    if (ok) {
        log.info("sent pre-roll wake_id={d} duration_ms={d} bytes={d} batches={d} send_ms={d}", .{
            wake_id,
            availableMs(),
            total_len,
            batch,
            @divTrunc(c.esp_timer_get_time() - started_us, 1000),
        });
    } else {
        // Truncation loses the newest window samples (nearest the live seam).
        log.err("send pre-roll truncated wake_id={d} sent_bytes={d} of {d} batches={d} send_ms={d}", .{
            wake_id,
            sent * @sizeOf(i16),
            total_len,
            batch,
            @divTrunc(c.esp_timer_get_time() - started_us, 1000),
        });
    }
    return ok;
}
