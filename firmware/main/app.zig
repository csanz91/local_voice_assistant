//! Sebastian firmware entry point.
//!
//! Boot → board bring-up → XVF DFU → codec init → audio pipeline → WiFi/SNTP →
//! load wake word model → idle detection loop.
//!
//! Idle loop (low power, no LiveKit):
//!   wakeword task reads I2S directly and feeds the okay_nabu streaming CNN.
//!   On detection → keep filling local pre-roll while opening LiveKit →
//!   hand off the mic when the room and agent are ready → silence timeout →
//!   close room → back to wake word detection.
//!
//! The XVF I2S RX channel is shared: the wakeword task owns it during idle,
//! mic_src.readFrame() owns it during the active session. Each hand-off includes
//! an i2s_channel_disable/enable resync to re-latch onto the running clock.
//!
//! Session choreography lives in core/session_reducer.zig (pure, host-tested):
//! the LiveKit callbacks push events into a FreeRTOS queue, the session loop
//! consumes them (the queue timeout IS the 10ms tick) and executes the actions
//! the reducer returns. This file is only the imperative shell.

const std = @import("std");
const board = @import("board.zig");
const cfg = @import("config.zig");
const device_identity = @import("identity.zig");
const mic_src = @import("mic_src.zig");
const profile = @import("profile.zig");
const selector = @import("selector.zig");
const usb_mic = @import("usb_mic.zig");
const xvf_dfu = @import("xvf_dfu.zig");
const xvf_ui = @import("xvf_ui.zig");
const wakeword = @import("wakeword.zig");
const xvf_aec = @import("xvf_aec.zig");
const pre_roll = @import("pre_roll.zig");
const arbiter_core = @import("core/arbiter_core.zig");
const session_core = @import("core/session_core.zig");
const device_voice = @import("core/device_voice.zig");
const reducer = @import("core/session_reducer.zig");
const token = @import("token.zig");
const c = @import("csdk.zig");

const log = std.log.scoped(.sebastian);

// Session timing constants + the pure keepalive/silence logic live in
// core/session_core.zig; the session choreography (thresholds, phases, retry
// cadence) in core/session_reducer.zig — both host-testable. These aliases
// keep the loop/watchdog call sites here readable.
const SESSION_TICK_MS: u32 = session_core.TICK_MS;
const SESSION_MAX_TICKS: u32 = session_core.MAX_TICKS;

var room: c.livekit_room_handle_t = null;
// Peak |render sample| (>>8) since the session loop last read it. Fed by the
// av_render reference callback (the speaker output), it is a data-channel-
// INDEPENDENT proof that the agent is talking — the keepalive that survives a
// dead SCTP link. Stays an atomic (NOT a queue event): the render thread
// produces it every few ms, so it is sampled into each tick via swap.
var render_peak = std.atomic.Value(u32).init(0);
var wake_seq: u32 = 0;
// The queue is only a latency hint. Authoritative fixed-size atomics retain
// critical observations even if every hint is dropped during a callback burst.
const EVENT_QUEUE_LEN: c_uint = 1;
var event_queue: c.QueueHandle_t = null;
var callback_mailbox = device_voice.Mailbox{};

fn pushEvent(event: reducer.Event) void {
    callback_mailbox.publish(event);
    const hint: u8 = 1;
    _ = c.xQueueGenericSend(event_queue, &hint, 0, 0);
}

const CaptureHandle = *anyopaque;
const RenderHandle = *anyopaque;

const AppError = error{
    LiveKitSystemInitFailed,
    DecoderRegistrationFailed,
    EncoderRegistrationFailed,
    MicSourceCreateFailed,
    CaptureOpenFailed,
    RendererAllocationFailed,
    RenderOpenFailed,
    NetworkConnectFailed,
    WifiPowerSaveFailed,
    TokenFetchFailed,
    RoomCreateFailed,
    RoomConnectFailed,
};

const AudioPipeline = struct {
    mic: CaptureHandle,
    speaker: RenderHandle,
};

const BootHealth = struct {
    xvf: bool = false,
    codecs: bool = false,
    audio: bool = false,
    ww: bool = false,

    fn ok(self: BootHealth) bool {
        return self.xvf and self.codecs and self.audio and self.ww;
    }
};

fn requireOk(result: c_int, comptime err: AppError) AppError!void {
    if (result == 0) return;
    return err;
}

fn requireLiveKitOk(result: c_int, comptime err: AppError) AppError!void {
    if (result == c.LIVEKIT_ERR_NONE) return;
    return err;
}

fn requireEspOk(result: c.esp_err_t, comptime err: AppError) AppError!void {
    if (result == c.ESP_OK) return;
    return err;
}

fn initLiveKitSystem() AppError!void {
    try requireOk(c.livekit_system_init(), error.LiveKitSystemInitFailed);
}

fn registerAudioCodecs() AppError!void {
    try requireOk(c.esp_audio_dec_register_default(), error.DecoderRegistrationFailed);
    try requireOk(c.esp_audio_enc_register_default(), error.EncoderRegistrationFailed);
}

fn buildCapturer() AppError!CaptureHandle {
    const src = mic_src.create(board.recordHandle());
    if (src == null) {
        log.err("mic source create failed", .{});
        return error.MicSourceCreateFailed;
    }

    var cfg_cap = std.mem.zeroes(c.esp_capture_cfg_t);
    cfg_cap.sync_mode = c.ESP_CAPTURE_SYNC_MODE_AUDIO;
    cfg_cap.audio_src = src;
    var handle: c.esp_capture_handle_t = null;
    if (c.esp_capture_open(&cfg_cap, &handle) != 0 or handle == null) {
        log.err("esp_capture_open failed", .{});
        return error.CaptureOpenFailed;
    }
    log.info("mic capture pipeline ready", .{});
    return handle.?;
}

/// av_render "reference output" callback: the PCM being played through the
/// speaker (48 kHz, 2ch, 32-bit). Non-silent output = the agent is speaking;
/// on underrun the I2S driver's auto_clear feeds exact zeros, so there is no
/// noise floor to confuse it. Runs in the render thread — subsample and keep it
/// cheap. Publishes the peak so the session loop can keep the session alive
/// while the agent talks, with no dependency on the agent_state data channel.
fn renderRefCb(data: ?[*]u8, size: c_int, _: ?*anyopaque) callconv(.c) c_int {
    const d = data orelse return 0;
    const count: usize = @intCast(@divTrunc(@max(0, size), 4)); // 32-bit samples
    var peak: u32 = 0;
    var i: usize = 0;
    while (i < count) : (i += 8) { // subsample every 8th sample
        const s = std.mem.readInt(i32, d[i * 4 ..][0..4], .little);
        const a: u32 = @abs(s) >> 8;
        if (a > peak) peak = a;
    }
    _ = render_peak.fetchMax(peak, .monotonic);
    return 0;
}

// Stashed for onDataReceived: the "interrupted" barge-in flush needs the render
// handle from a C callback that has no access to the AudioPipeline.
var speaker_render: c.av_render_handle_t = null;

fn buildRenderer() AppError!RenderHandle {
    var i2s_cfg = std.mem.zeroes(c.i2s_render_cfg_t);
    i2s_cfg.play_handle = board.playbackHandle();
    i2s_cfg.cb = @ptrCast(&renderRefCb); // speaker-output tap → agent-audio keepalive
    i2s_cfg.fixed_clock = true;
    const audio_render = c.av_render_alloc_i2s_render(&i2s_cfg);
    if (audio_render == null) {
        log.err("av_render_alloc_i2s_render failed", .{});
        return error.RendererAllocationFailed;
    }

    var cfg_rend = std.mem.zeroes(c.av_render_cfg_t);
    cfg_rend.audio_render = audio_render;
    cfg_rend.audio_raw_fifo_size = 4 * 4096;
    cfg_rend.audio_render_fifo_size = 24 * 1024;
    cfg_rend.allow_drop_data = true;
    const handle = c.av_render_open(&cfg_rend);
    if (handle == null) {
        log.err("av_render_open failed", .{});
        return error.RenderOpenFailed;
    }

    var frame = std.mem.zeroes(c.av_render_audio_frame_info_t);
    frame.sample_rate = 48000;
    frame.channel = 2;
    frame.bits_per_sample = 32;
    // av_render bug: set_fixed_frame_info stores the info but always returns
    // ESP_MEDIA_ERR_WRONG_STATE (ret is never set to 0) — ignore the code.
    _ = c.av_render_set_fixed_frame_info(handle, &frame);
    speaker_render = handle;
    log.info("speaker render pipeline ready", .{});
    return handle.?;
}

fn buildAudioPipeline() AppError!AudioPipeline {
    const mic = try buildCapturer();
    const speaker = try buildRenderer();
    return .{ .mic = mic, .speaker = speaker };
}

fn startSntp() void {
    c.esp_sntp_setoperatingmode(0);
    c.esp_sntp_setservername(0, "pool.ntp.org");
    c.esp_sntp_init();
    c.vTaskDelay(3000);
}

fn onStateChanged(state: c_int, ctx: ?*anyopaque) callconv(.c) void {
    if (!currentCallback(ctx)) return;
    if (state == 3 or state == c.LIVEKIT_CONNECTION_STATE_FAILED) {
        receive_gate.store(true, .release);
        pushEvent(.{ .agent_state = .close });
    }
    log.info("room state: {s}", .{std.mem.span(c.livekit_connection_state_str(state))});
}

// Each room gets a distinct callback generation; old callbacks cannot mutate a
// later room. KIND_AGENT is server classified in the per-call private room.
var callback_generation: usize = 0;
var active_generation = std.atomic.Value(usize).init(0);
var agent_identity = device_voice.Identity{};
var agent_sid = device_voice.Identity{};
var agent_bound = std.atomic.Value(bool).init(false);
var local_mic_sid: [128:0]u8 = [_:0]u8{0} ** 128;
var receive_gate = std.atomic.Value(bool).init(false);
var received_audio = std.atomic.Value(bool).init(false);

var remote_speaking = std.atomic.Value(bool).init(false);
var wake_pending = std.atomic.Value(bool).init(false);
var wake_request: [65:0]u8 = [_:0]u8{0} ** 65;
var wake_payload: [384]u8 = undefined;
var wake_counter = std.atomic.Value(u32).init(0);
var wake_drain = device_voice.Drain{};
// Session task only. Every new request starts its own elapsed-time origin.
var wake_drain_started_us: i64 = 0;

extern fn sebastian_wake_result(bytes: [*]const u8, size: usize, request: [*:0]const u8) c_int;
fn currentCallback(ctx: ?*anyopaque) bool {
    const generation = active_generation.load(.acquire);
    return device_voice.currentSession(generation, @intFromPtr(ctx));
}
fn onParticipantInfo(info: *const c.livekit_participant_info_t, ctx: ?*anyopaque) callconv(.c) void {
    if (!currentCallback(ctx) or info.kind != c.LIVEKIT_PARTICIPANT_KIND_AGENT) return;
    const identity = info.identity orelse return;
    const name = std.mem.span(identity);
    const sid = std.mem.span(info.sid orelse return);
    if (!agent_bound.load(.acquire)) {
        if (info.state != c.LIVEKIT_PARTICIPANT_STATE_ACTIVE or !agent_identity.bind(name) or !agent_sid.bind(sid)) return;
        agent_bound.store(true, .release);
    }
    if (!agent_identity.matches(name) or !agent_sid.matches(sid)) return;
    if (info.state != c.LIVEKIT_PARTICIPANT_STATE_ACTIVE) {
        pushEvent(.{ .agent_state = .close });
        return;
    }
    if (info.tracks) |tracks| {
        for (tracks[0..info.tracks_count]) |track| {
            if (track.type == 0 and std.mem.eql(u8, std.mem.span(track.name orelse continue), "roomio_audio"))
                pushEvent(.{ .agent_active = true });
        }
    }
    if (info.attributes) |attrs| {
        for (attrs[0..info.attributes_count]) |attr| {
            if (!std.mem.eql(u8, std.mem.span(attr.key), "lk.agent.state")) continue;
            const state = std.mem.span(attr.value);
            const listening = std.mem.eql(u8, state, "listening");
            remote_speaking.store(std.mem.eql(u8, state, "speaking"), .release);
            // Publish detector transitions before latest UI state coalesces;
            // a short quiet->speaking transition must still re-arm capture.
            if (listening or std.mem.eql(u8, state, "speaking") or
                std.mem.eql(u8, state, "thinking") or std.mem.eql(u8, state, "initializing"))
                mic_src.noteAgentState(std.mem.eql(u8, state, "speaking"));
            if (std.mem.eql(u8, state, "speaking")) pushEvent(.{ .agent_state = .speaking }) else if (listening) pushEvent(.{ .agent_state = .quiet }) else if (std.mem.eql(u8, state, "thinking") or std.mem.eql(u8, state, "initializing"))
                pushEvent(.{ .agent_state = .thinking });
        }
    }
}
fn onLocalTrackPublished(_: [*:0]const u8, track: *const c.livekit_track_info_t, ctx: ?*anyopaque) callconv(.c) void {
    if (!currentCallback(ctx) or track.type != 0 or track.source != 2) return;
    const sid = std.mem.span(track.sid orelse return);
    if (sid.len == 0 or sid.len >= local_mic_sid.len or local_mic_sid[0] != 0) return;
    @memcpy(local_mic_sid[0..sid.len], sid);
    local_mic_sid[sid.len] = 0;
    pushEvent(.{ .mic_published = true });
}
fn selectVoiceTrack(sid: [*:0]const u8, name: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) bool {
    return currentCallback(ctx) and agent_bound.load(.acquire) and agent_sid.matches(std.mem.span(sid)) and std.mem.eql(u8, std.mem.span(name), "roomio_audio");
}
fn audioReceiveFilter(ctx: ?*anyopaque) callconv(.c) bool {
    if (!currentCallback(ctx)) return false;
    received_audio.store(true, .monotonic);
    return !receive_gate.load(.acquire);
}
fn onLocalWake() void {
    if (active_generation.load(.acquire) == 0) return;
    // Drop incoming audio at the transport/renderer boundary immediately. The
    // event wakes the session task to flush queued PCM and send control.
    receive_gate.store(true, .release);
    pushEvent(.local_wake);
}
fn publishBargeIn() void {
    if (wake_pending.load(.acquire)) return;
    var sequence = wake_counter.fetchAdd(1, .monotonic) +% 1;
    if (sequence == 0) sequence = wake_counter.fetchAdd(1, .monotonic) +% 1;
    const request = std.fmt.bufPrintZ(&wake_request, "{d}-{d}", .{ callback_generation, sequence }) catch return;
    const json = std.fmt.bufPrint(&wake_payload, "{{\"version\":2,\"request_id\":\"{s}\",\"room\":\"{s}\"}}", .{ request, token.roomName() }) catch return;
    wake_drain_started_us = c.esp_timer_get_time();
    wake_drain.start();
    wake_pending.store(true, .release);
    if (!publishToAgent("iotcloud.device.wake", @constCast(json)))
        log.warn("wake control publish failed; drain timeout will close session", .{});
}

fn publishToAgent(topic: [*:0]const u8, bytes: []u8) bool {
    var payload = c.livekit_data_payload_t{ .bytes = bytes.ptr, .size = @intCast(bytes.len) };
    var destinations = [_][*:0]const u8{@ptrCast(&agent_identity.bytes)};
    var opts = c.livekit_data_publish_options_t{
        .payload = &payload,
        .topic = topic,
        .lossy = false,
        .destination_identities = &destinations,
        .destination_identities_count = 1,
    };
    return c.livekit_room_publish_data(room, &opts) == c.LIVEKIT_ERR_NONE;
}

var credit_ack = std.atomic.Value(u32).init(0);
fn confirmPrerollBatch(batch: u32, deadline_us: i64) bool {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, batch, .little);
    if (!publishToAgent("iotcloud.device.preroll.credit", &bytes)) return false;
    while (c.esp_timer_get_time() < deadline_us) {
        if (credit_ack.load(.acquire) == batch) return true;
        if (callback_mailbox.close.load(.acquire) or mic_src.isMuted()) return false;
        c.vTaskDelay(1);
    }
    return false;
}
fn onDataReceived(data: *const c.livekit_data_received_t, ctx: ?*anyopaque) callconv(.c) void {
    if (!currentCallback(ctx) or !agent_bound.load(.acquire)) return;
    const sender = data.sender_identity orelse return;
    if (!agent_identity.matches(std.mem.span(sender))) return;
    const topic = data.topic orelse return;
    const bytes = data.payload.bytes orelse return;
    if (std.mem.eql(u8, std.mem.span(topic), "iotcloud.device.preroll.credit.ack")) {
        if (data.payload.size == 4) credit_ack.store(std.mem.readInt(u32, bytes[0..4], .little), .release);
        return;
    }
    if (!wake_pending.load(.acquire) or !std.mem.eql(u8, std.mem.span(topic), "iotcloud.device.wake.result")) return;
    var expected_buf: [65]u8 = undefined;
    const sequence = wake_counter.load(.monotonic);
    const expected = std.fmt.bufPrintZ(&expected_buf, "{d}-{d}", .{ @intFromPtr(ctx), sequence }) catch return;
    const result = sebastian_wake_result(bytes, data.payload.size, expected);
    if (result != 0) pushEvent(.{ .wake_result = .{ .sequence = sequence, .outcome = switch (result) { 1 => .accepted, -1 => .policy, else => .failed } } });
}

fn connectNetwork() AppError!void {
    // NVS-provisioned WiFi; factory images contain no credentials.
    if (!c.sebastian_net_connect()) return error.NetworkConnectFailed;
    try requireEspOk(c.esp_wifi_set_ps(c.WIFI_PS_NONE), error.WifiPowerSaveFailed);
    startSntp();
}

fn openSession(audio: AudioPipeline, conn: token.Connection) AppError!void {
    var opts = std.mem.zeroes(c.livekit_room_options_t);
    opts.subscribe.kind = c.LIVEKIT_MEDIA_TYPE_AUDIO;
    opts.subscribe.renderer = audio.speaker;
    opts.publish.kind = c.LIVEKIT_MEDIA_TYPE_AUDIO;
    opts.publish.audio_encode.codec = c.LIVEKIT_AUDIO_CODEC_OPUS;
    opts.publish.audio_encode.sample_rate = 48000;
    opts.publish.audio_encode.channel_count = 1;
    opts.publish.capturer = audio.mic;
    opts.ctx = @ptrFromInt(callback_generation);
    opts.enable_preconnect_buffer = true;
    opts.on_local_track_published = onLocalTrackPublished;
    opts.audio_receive_filter = audioReceiveFilter;
    opts.audio_track_filter = selectVoiceTrack;
    opts.on_state_changed = onStateChanged;
    opts.on_participant_info = onParticipantInfo;
    opts.on_data_received = onDataReceived;

    try requireLiveKitOk(c.livekit_room_create(&room, &opts), error.RoomCreateFailed);
    // If connect fails, destroy the room we just created. Without this the
    // half-open room leaks with its tasks alive (websocket, peer, SCTP retry
    // loops) and the next session creates a new room over the same handle —
    // the source of the endless "SCTP: Send INIT chunk" storms.
    errdefer {
        _ = c.livekit_room_close(room);
        _ = c.livekit_room_destroy(room);
        room = null;
    }
    logHeap("pre-connect");
    try requireLiveKitOk(c.livekit_room_connect(room, conn.server_url, conn.token), error.RoomConnectFailed);
    logHeap("post-connect");
    log.info("session open", .{});
}

fn closeSession() void {
    active_generation.store(0, .release);
    wake_pending.store(false, .release);
    if (room == null) return;
    _ = c.livekit_room_close(room);
    _ = c.livekit_room_destroy(room);
    room = null;
    log.info("session closed", .{});
}

// Free internal-RAM telemetry. The scarce pool is internal DMA-capable RAM: the
// TLS hardware-AES DMA and the WebRTC/WiFi stacks all draw from it, and it is
// what starved during the WSS handshake (the 15KB-probe-buffer regression). Log
// it at boot and around room_connect so the real headroom is a measured number,
// not a guess.
fn logHeap(label: []const u8) void {
    const int_free = c.heap_caps_get_free_size(c.MALLOC_CAP_INTERNAL);
    const int_big = c.heap_caps_get_largest_free_block(c.MALLOC_CAP_INTERNAL);
    const dma_free = c.heap_caps_get_free_size(c.MALLOC_CAP_INTERNAL | c.MALLOC_CAP_DMA);
    const dma_big = c.heap_caps_get_largest_free_block(c.MALLOC_CAP_INTERNAL | c.MALLOC_CAP_DMA);
    log.info("heap[{s}] internal free={d} largest={d} | dma free={d} largest={d}", .{
        label, int_free, int_big, dma_free, dma_big,
    });
}

// ── Session watchdog ──────────────────────────────────────────────────────────
// livekit_room_close can block forever on a wedged connection (observed: main
// loop frozen, device mute until manual reset). A separate task enforces a
// hard deadline armed around every session; if the main loop doesn't disarm
// in time, reboot clean (~8s back to listening) instead of hanging for good.

var wdg_deadline_s = std.atomic.Value(i32).init(0); // 0 = disarmed (Xtensa: 32-bit atomics only)

fn nowSeconds() i32 {
    return @intCast(@divTrunc(c.esp_timer_get_time(), 1_000_000));
}

fn wdgArm(seconds: i32) void {
    wdg_deadline_s.store(nowSeconds() + seconds, .release);
}

fn wdgDisarm() void {
    wdg_deadline_s.store(0, .release);
}

fn wdgTask(_: ?*anyopaque) callconv(.c) void {
    while (true) {
        c.vTaskDelay(1000);
        const deadline = wdg_deadline_s.load(.acquire);
        if (deadline != 0 and nowSeconds() > deadline) {
            log.err("session watchdog expired — restarting", .{});
            c.vTaskDelay(200); // let the log flush
            c.esp_restart();
        }
    }
}

/// Why the chip last reset, in the ROM's `rst:0x..` shape so the telemetry
/// bridge counts it as a reboot with its reason. Emitted once the syslog sink is
/// up: a watchdog, a panic and a brownout all look identical from Loki
/// otherwise (silence, then BOOT OK), and that ambiguity cost a whole session.
fn logResetReason() void {
    const code = c.esp_reset_reason();
    const name: []const u8 = switch (code) {
        1 => "POWERON",
        2 => "EXT",
        3 => "SW",
        4 => "PANIC",
        5 => "INT_WDT",
        6 => "TASK_WDT",
        7 => "WDT",
        8 => "DEEPSLEEP",
        9 => "BROWNOUT",
        10 => "SDIO",
        11 => "USB",
        12 => "JTAG",
        13 => "EFUSE",
        14 => "PWR_GLITCH",
        15 => "CPU_LOCKUP",
        else => "UNKNOWN",
    };
    log.info("reset reason rst:0x{x} ({s})", .{ @as(u32, @intCast(@max(0, code))), name });
}

fn logStageError(comptime stage: []const u8, err: anyerror) void {
    log.err("{s} failed: {s}", .{ stage, @errorName(err) });
}

fn confirmXvfMaster() bool {
    xvf_dfu.ensureMaster(board.i2cBus()) catch |err| {
        logStageError("XVF master firmware confirmation", err);
        return false;
    };
    return true;
}

fn unmuteXvf() bool {
    xvf_dfu.unmute() catch |err| {
        logStageError("XVF unmute", err);
        return false;
    };
    return true;
}

fn fullDuplexAllowed(aec_configured: bool) bool {
    if (!cfg.full_duplex) return false;
    if (!aec_configured) {
        // Both paths need the verified XVF config: path A for the converged
        // linear AEC, path B because FAR_END_DSP_ENABLE=1 is also what feeds
        // the far-end reference to the comms residual suppressor.
        log.err("full-duplex requested but AEC config failed — forcing half-duplex", .{});
        return false;
    }
    if (cfg.mic_channel == .left) {
        // Path B (comms beam): the non-linear residual suppressor cancels the
        // loudspeaker echo WITHOUT a converged linear AEC and WITH the adaptive
        // beam (hardware-validated, probeDualChannel: echo-rise −2 568 vs
        // +101 655 raw). A fixed beam is not a prerequisite on this channel —
        // full-duplex WITH talker tracking.
        return true;
    }
    // Path A (raw ASR beam): only the converged linear AEC protects the mic,
    // and it only converges on a fixed beam.
    if (!cfg.fixed_beam) {
        log.err("full-duplex requested but fixed_beam=false — forcing half-duplex", .{});
        return false;
    }
    return true;
}

fn configureFullDuplex(aec_configured: bool) void {
    mic_src.setFullDuplex(fullDuplexAllowed(aec_configured));
}

fn startWakeDetection() void {
    xvf_ui.setState(.idle); // ring: dim breath — armed, not listening
    log.info("waiting for wake word…", .{});
    wakeword.start();
}

fn grantUsbFromIdle() void {
    wakeword.stop(); // releases I2S (+ resync) for the incoming consumer
    usb_mic.grant();
    xvf_ui.setState(.usb); // ring: amber DoA beam — the PC has the mic
}

fn revokeUsbToIdle() void {
    usb_mic.revoke();
    wakeword.start();
    xvf_ui.setState(.idle);
}

fn waitForWakeWord() void {
    // Convivencia: while idling for the wake word, the USB host can borrow
    // the mic — usage-driven, zero config (core/arbiter_core hysteresis).
    // Ownership changes execute HERE, on the single agent task, so they can
    // never race the wake/session hand-offs.
    var arb = arbiter_core.Arbiter{};
    while (!wakeword.detected.load(.acquire)) {
        if (arb.feed(usb_mic.hostCapturing())) |transition| switch (transition) {
            .grant_usb => grantUsbFromIdle(),
            .revoke_usb => revokeUsbToIdle(),
        };
        c.vTaskDelay(arbiter_core.TICK_MS);
    }
    // Rare race: detection latched in the same tick the mic went to USB.
    // Restore the agent's ownership so the session hand-off starts clean.
    if (arb.owner == .usb) revokeUsbToIdle();
    xvf_ui.setState(.waking); // ring: orbiting pixel — heard you, connecting
    log.info("wake word confirmed — fetching token", .{});
}

fn fetchConnectionAfterWake() ?token.Connection {
    return token.fetch() catch |err| {
        wakeword.stop(); // stop task and resync I2S for the next idle cycle
        logStageError("token fetch", err);
        c.vTaskDelay(2000);
        return null;
    };
}

fn nextWakeId() u32 {
    wake_seq +%= 1;
    return wake_seq;
}

fn openSessionForWake(audio: AudioPipeline, conn: token.Connection, wake_id: u32) bool {
    log.info("opening session wake_id={d}", .{wake_id});
    // Session hygiene BEFORE the room exists: drop any event raced from the end
    // of the previous session (a late "close" must not kill this one at tick 0)
    // and any speaker tail still in the render-peak accumulator.
    _ = c.xQueueGenericReset(event_queue, 0);
    render_peak.store(0, .monotonic);
    callback_generation +%= 1;
    if (callback_generation == 0) callback_generation = 1;
    agent_bound.store(false, .release);
    agent_identity = .{};
    agent_sid = .{};
    local_mic_sid = [_:0]u8{0} ** 128;
    callback_mailbox = .{};
    credit_ack.store(0, .release);
    wake_pending.store(false, .release);
    wake_drain = .{};
    receive_gate.store(false, .release);
    received_audio.store(false, .monotonic);
    remote_speaking.store(false, .release);
    active_generation.store(callback_generation, .release);
    // Budget: max session + connect/close margin. Disarmed after teardown;
    // if anything below wedges, the watchdog reboots us back to listening.
    wdgArm(@as(i32, SESSION_MAX_TICKS * SESSION_TICK_MS / 1000) + 45);
    openSession(audio, conn) catch |err| {
        active_generation.store(0, .release);
        logStageError("session open", err);
        wakeword.stop();
        wdgDisarm();
        c.vTaskDelay(2000); // brief cooldown before retrying wake word
        return false;
    };
    return true;
}

fn classifyConnection(state: c_int) reducer.Connection {
    if (state == c.LIVEKIT_CONNECTION_STATE_CONNECTED) return .connected;
    if (state == c.LIVEKIT_CONNECTION_STATE_DISCONNECTED or
        state == c.LIVEKIT_CONNECTION_STATE_FAILED) return .ended;
    return .connecting;
}

fn sampleTick(raw_state: *c_int) reducer.Event {
    raw_state.* = c.livekit_room_get_state(room);
    return .{
        .tick = .{
            .connection = classifyConnection(raw_state.*),
            .mic_level = mic_src.level(),
            .render_peak = render_peak.swap(0, .monotonic),
            .barge_request = false, // local wake is latched in callback_mailbox
        },
    };
}

fn completeWakeHandoff(st: *reducer.State, wake_id: u32) void {
    // Timed: the handoff seam is where start-of-session micro-cuts happen
    // (recordings show razor-cut frames right here). stop_ms is how long the
    // live mic waited for the wake task to exit; send_ms is the pre-roll
    // data-channel burst that competes with the first live audio frames.
    const t0 = c.esp_timer_get_time();
    wakeword.stop();
    const t_stop = c.esp_timer_get_time();
    mic_src.setLive(true); // RoomIO holds the live stream behind native pre-roll.
    const sent = !mic_src.isMuted() and pre_roll.send(room, wake_id, &local_mic_sid, confirmPrerollBatch);
    const t_send = c.esp_timer_get_time();
    log.info("mic handoff wake_id={d} pre_roll_ms={d} stop_ms={d} send_ms={d}", .{
        wake_id,
        pre_roll.availableMs(),
        @divTrunc(t_stop - t0, 1000),
        @divTrunc(t_send - t_stop, 1000),
    });
    _ = st.step(.{ .preroll_sent = sent });
}

fn logAecDiagnostics(win: reducer.AecLog) void {
    xvf_aec.logState();
    log.info("echo: gated_peak={d} live_echo={d} render_peak={d} keepalive={}", .{
        mic_src.takeGatedPeak(),
        win.echo_window,
        win.render_peak_window,
        win.keepalive,
    });

    // Capture health — nonzero means the published voice had micro-cuts
    // this window (short reads / timeouts / heals). warn so Grafana's log
    // panel surfaces it; silent when healthy.
    const rs = mic_src.takeReadStats();
    if (!rs.healthy()) {
        log.warn("mic capture: short_reads={d} pad_samples={d} timeouts={d} heals={d}", .{
            rs.short_reads, rs.pad_samples, rs.timeouts, rs.heals,
        });
    }
}

fn applyActions(st: *reducer.State, actions: reducer.Actions, wake_id: u32) void {
    // Latency-sensitive first: the half-duplex gate and the barge-in flush.
    if (actions.mic_gate) |speaking| mic_src.setAgentSpeaking(speaking and !wake_pending.load(.acquire));
    if (actions.flush_render) {
        // Barge-in: the agent aborted mid-speech, but SECONDS of its reply can
        // still sit in the render FIFO (the model generates faster than
        // realtime), so the speaker keeps narrating after the model went quiet
        // ("no para"). Dump everything queued; the stream stays open for new
        // audio (av_render_flush, not reset).
        if (speaker_render != null) _ = c.av_render_flush(speaker_render);
        log.info("agent interrupted — render FIFO flushed", .{});
    }
    if (actions.publish_barge) {
        _ = mic_src.takeBargeRequest();
        publishBargeIn();
    }
    if (actions.ui_active) xvf_ui.setState(.active); // ring: DoA beam — I'm listening
    if (actions.handoff) completeWakeHandoff(st, wake_id);
    if (actions.ui_state) |state| {
        xvf_ui.setState(switch (state) {
            .speaking => .speaking,
            .thinking => .thinking,
            else => .active,
        });
    }
    if (actions.log_aec) |win| logAecDiagnostics(win);
}

fn logSessionClose(st: *const reducer.State, reason: reducer.CloseReason, raw_state: c_int) void {
    // These lines feed tools/telemetry/bridge.py (RE_CLOSE_REASON) — the
    // phrases "disconnected early", "agent close", "silence timeout" and
    // "max duration" are load-bearing.
    const quiet_ms = (st.timing.tick - st.timing.last_voice_tick) * SESSION_TICK_MS;
    switch (reason) {
        .disconnected => log.info("room disconnected early (state={})", .{raw_state}),
        .agent_close => log.info("session agent close: quiet_ms={d}", .{quiet_ms}),
        .silence => log.info("session silence timeout: level={d} threshold={d} quiet_ms={d}", .{
            st.last_level, reducer.VOICE_LEVEL, quiet_ms,
        }),
        .max_duration => log.info("session max duration reached ({d} ms) — closing", .{SESSION_MAX_TICKS * SESSION_TICK_MS}),
    }
}

fn runActiveSession(wake_id: u32) void {
    var st = reducer.State{};
    var raw_state: c_int = c.LIVEKIT_CONNECTION_STATE_DISCONNECTED;
    var usb_capture_ticks: u32 = 0;
    var last_tick_us = c.esp_timer_get_time();
    var last_drain_us = last_tick_us;
    while (true) {
        var hint: u8 = 0;
        _ = c.xQueueReceive(event_queue, &hint, SESSION_TICK_MS);
        const snapshot = callback_mailbox.take();
        // Close is sticky and wins over wake/readiness observations in this
        // snapshot. No dropped queue notification can postpone it indefinitely.
        if (snapshot.close) {
            applyActions(&st, st.step(.{ .agent_state = .close }), wake_id);
        } else {
            _ = st.step(.{ .agent_active = snapshot.agent_ready });
            _ = st.step(.{ .mic_published = snapshot.mic_ready });
            if (snapshot.state) |state| applyActions(&st, st.step(.{ .agent_state = state }), wake_id);
            if (snapshot.local_wake) applyActions(&st, st.step(.local_wake), wake_id);
            const sequence = wake_counter.load(.monotonic);
            if (wake_pending.load(.acquire) and snapshot.failed_sequence == sequence) {
                // not_ready/timeout/invalid: the old reply may still be live.
                // Keep output gated and close; only "policy" may restore it.
                log.warn("wake control failed for request {d}; closing session", .{sequence});
                st.phase = .{ .done = .agent_close };
            }
            if (sequence != 0 and snapshot.accepted_sequence == sequence) wake_drain.acknowledge(true) else if (sequence != 0 and snapshot.rejected_sequence == sequence) wake_drain.acknowledge(false);
        }
        const tick_due = c.esp_timer_get_time() - last_tick_us >= SESSION_TICK_MS * 1000;
        if (tick_due) {
            last_tick_us = c.esp_timer_get_time();
            applyActions(&st, st.step(sampleTick(&raw_state)), wake_id);

            const drain_now_us = c.esp_timer_get_time();
            const drain_ms = device_voice.drainElapsedMs(last_drain_us, wake_drain_started_us, drain_now_us);
            last_drain_us = drain_now_us;
            switch (wake_drain.advance(drain_ms, received_audio.swap(false, .monotonic))) {
                .none => {},
                .reopen => {
                    // Flush again before reopening: ACK is never an RTP barrier.
                    if (speaker_render != null) _ = c.av_render_flush(speaker_render);
                    wake_pending.store(false, .release);
                    receive_gate.store(false, .release);
                    if (wake_drain.result == .accepted) {
                        // Open the renderer before releasing the agent's held next reply.
                        if (!publishToAgent("iotcloud.device.wake.resume", std.mem.sliceTo(&wake_request, 0))) {
                            log.warn("wake resume publish failed; closing session", .{});
                            receive_gate.store(true, .release);
                            st.phase = .{ .done = .agent_close };
                        }
                    }
                    // A policy rejection leaves the original noninterruptible
                    // speech active; restore its real half-duplex mic gate.
                    mic_src.setAgentSpeaking(remote_speaking.load(.acquire));
                },
                .close => {
                    log.warn("wake drain unresolved after {d} ms; closing session", .{device_voice.Drain.TIMEOUT_MS});
                    st.phase = .{ .done = .agent_close };
                },
            }
        }
        // Convivencia: sustained USB capture mid-session means the user is at
        // the PC deliberately using the mic — close cleanly; the idle loop
        // grants ownership right after teardown.
        if (tick_due) usb_capture_ticks = if (usb_mic.hostCapturing()) usb_capture_ticks + 1 else 0;
        if (usb_capture_ticks * SESSION_TICK_MS >= arbiter_core.RESUME_AFTER_MS) {
            usb_capture_ticks = 0;
            log.info("USB capture takeover — closing session", .{});
            pushEvent(.{ .agent_state = .close });
        }
        switch (st.phase) {
            .done => |reason| return logSessionClose(&st, reason, raw_state),
            else => {},
        }
    }
}

fn teardownActiveSession() void {
    wakeword.stop(); // no-op if the handoff already stopped it
    mic_src.setLive(false);
    mic_src.setAgentSpeaking(false); // never carry a stale gate into the next session
    wdgArm(25); // close budget — livekit_room_close has hung forever before
    closeSession();
    wdgDisarm();
    // Field bug 2026-09-17: after a session the internal heap reported a
    // 384 KiB "largest free block" (impossible on an S3) and the NEXT session
    // panicked with no core dump. Check here, right after the teardown, so a
    // corruption is attributed to the session that caused it.
    if (c.heap_caps_check_integrity_all(true)) {
        logHeap("post-session");
    } else {
        log.err("HEAP CORRUPTED after session teardown — see the block addresses above", .{});
    }
    xvf_aec.logState(); // post-session: did the AEC converge this session?
    // Let the speaker's render FIFO drain before re-arming detection — the agent
    // says its own name and a tail leaking into the mic would immediately re-trigger.
    c.vTaskDelay(1500);
}

fn runWakeCycle(audio: AudioPipeline) void {
    startWakeDetection();
    waitForWakeWord();

    // The wake task keeps draining I2S into the pre-roll ring through token fetch
    // and connect; LiveKit remains disconnected here, so IDLE costs zero minutes.
    const conn = fetchConnectionAfterWake() orelse return;
    const wake_id = nextWakeId();
    if (!openSessionForWake(audio, conn, wake_id)) return;

    runActiveSession(wake_id);
    teardownActiveSession();
}

// USB-serial provisioning window: TinyUSB claims the S3's only USB PHY at
// initUac(), so these boot seconds are the only serial the device ever has —
// in BOTH modes now (convivencia keeps the UAC device up alongside the
// agent). Overlapped with the XVF bring-up, so the real added latency is
// window minus bring-up time.
const USB_PROVISION_WINDOW_MS: u32 = 5000;

export fn app_main() callconv(.c) void {
    // Boot-failure guard: incremented now, cleared once the selected mode is
    // up. Three straight failures ⇒ fall back to an agent profile below (the
    // mode that is always administrable) instead of boot-looping.
    const boot_failures = profile.bootNoteStart();

    if (!device_identity.init()) {
        log.err("device identity initialization failed — halting", .{});
        return;
    }

    board.init() catch |err| {
        log.err("board init failed: {s} — halting", .{@errorName(err)});
        return;
    };

    // Serial provisioning receiver, first thing: the window below is the only
    // moment sebastian.config.v1 / sebastian.profile.set can arrive over USB.
    c.sebastian_provisioning_start();
    const boot_us = c.esp_timer_get_time();

    // Config layering: legacy NVS keys / compiled defaults first (cfg.load),
    // then the active profile's set fields overlay them (applyActive, after
    // the selector had its chance to change the active profile).
    cfg.load();
    profile.load();
    if (boot_failures >= 3) profile.forceAgentFallback();

    const xvf_master = confirmXvfMaster();
    const xvf_unmuted = unmuteXvf();
    // Double-tap the mute button in the first 2 s → on-ring profile selector.
    // Before xvf_ui.start() so the ring and the button are exclusively ours.
    if (xvf_master and xvf_unmuted) selector.maybeRun();
    profile.applyActive();

    // applyConfig writes the gains + fixes the beam, all readback-verified; it
    // returns false if any of that didn't take (e.g. the beam is not actually
    // fixed → the AEC can't converge).
    const aec_configured = xvf_aec.applyConfig();
    xvf_ui.start();
    const xvf_ok = xvf_master and xvf_unmuted and aec_configured;
    xvf_aec.logConfig(); // reference-chain snapshot (AEC diagnostics)
    // AEC convergence self-test (config.probe_aec_on_boot): plays a session-level
    // tone and reports converged — tests the REF_GAIN fix with no session/human.
    if (cfg.probe_aec_on_boot) xvf_aec.probeReference();
    if (cfg.probe_dual_channel_on_boot) xvf_aec.probeDualChannel();
    if (cfg.probe_output_gain_on_boot) xvf_aec.probeOutputGain();

    // Let the USB-serial window elapse, then hand the PHY to TinyUSB. The mic
    // interface exists in BOTH modes (convivencia); plugged into a charger it
    // simply never enumerates.
    const elapsed: u32 = @intCast(@min(
        @as(i64, USB_PROVISION_WINDOW_MS),
        @divTrunc(c.esp_timer_get_time() - boot_us, 1000),
    ));
    if (elapsed < USB_PROVISION_WINDOW_MS) c.vTaskDelay(USB_PROVISION_WINDOW_MS - elapsed);
    // The installer's "load from device" holds the window so the edited config
    // can come back on the same port (provisioning.c, 120 s after each get).
    if (c.sebastian_provisioning_hold()) {
        log.info("USB-serial window held open by the installer", .{});
        while (c.sebastian_provisioning_hold()) c.vTaskDelay(100);
        log.info("USB-serial window released", .{});
    }
    c.sebastian_provisioning_stop();
    _ = usb_mic.initUac();
    if (mic_src.create(board.recordHandle())) |src| usb_mic.bindMicSource(src);
    logHeap("post-uac");

    switch (profile.activeMode()) {
        .usb_mic => usb_mic.run(xvf_ok),
        .agent => {
            runAgent(xvf_ok, aec_configured);
            // runAgent only returns when a boot stage failed. A degraded
            // agent is still a microphone: the USB host keeps the mic.
            usb_mic.grant();
            xvf_ui.setState(.usb);
            log.err("agent halted — USB mic keeps serving", .{});
        },
    }
}

fn runAgent(xvf_ok: bool, aec_configured: bool) void {
    var health = BootHealth{};
    health.xvf = xvf_ok;

    initLiveKitSystem() catch |err| {
        logStageError("livekit system init", err);
        return;
    };

    configureFullDuplex(aec_configured);
    mic_src.on_local_wake = onLocalWake;

    registerAudioCodecs() catch |err| {
        logStageError("audio codec registration", err);
        return;
    };
    health.codecs = true;

    const audio = buildAudioPipeline() catch |err| {
        logStageError("audio pipeline", err);
        return;
    };
    health.audio = true;

    // Boot counts as good from here: provisioning is listening and the audio
    // stack is sane — the device is administrable. Deliberately BEFORE
    // connectNetwork: a WiFi outage is not a broken boot, and counting it as
    // one made the safe-boot fallback hijack the profile in the field.
    profile.bootNoteOk();

    connectNetwork() catch |err| {
        logStageError("network", err);
        return;
    };

    // Network is up: start mirroring logs to the remote syslog server, so the
    // device's serial output reaches Loki even though nothing reads its UART in
    // prod (power + WiFi only). No-op if syslog_ip is unprovisioned.
    c.sebastian_syslog_start();
    logResetReason();
    c.sebastian_coredump_report();

    if (wakeword.init()) {
        health.ww = true;
        log.info("wake word model loaded (okay_nabu, 59KB)", .{});
    } else {
        log.err("wake word model init failed — halting", .{});
        return;
    }
    _ = pre_roll.init();

    if (health.ok()) {
        log.info("BOOT OK — XVF master, codecs, mic+speaker, model loaded", .{});
    } else {
        log.err("BOOT DEGRADED — xvf={} codecs={} audio={} ww={}", .{
            health.xvf, health.codecs, health.audio, health.ww,
        });
    }
    logHeap("boot");

    event_queue = c.xQueueGenericCreate(EVENT_QUEUE_LEN, @sizeOf(u8), 0);
    if (event_queue == null) {
        log.err("session event queue allocation failed — halting", .{});
        return;
    }

    // Watchdog on core 1, above the main loop's priority: it must run even if
    // the main task wedges inside a blocking LiveKit call.
    _ = c.xTaskCreatePinnedToCore(wdgTask, "session_wdg", 3072, null, 5, null, 1);

    while (true) {
        runWakeCycle(audio);
    }
}

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    log.err("PANIC: {s}", .{msg});
    c.abort();
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = @import("log.zig").espLogFn,
};
pub const panic = std.debug.FullPanic(panicFn);
