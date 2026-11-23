//! Native RoomIO handoff and conservative wake renderer drain policy.
const std = @import("std");
pub fn currentSession(active: usize, callback: usize) bool {
    return active != 0 and active == callback;
}

pub const Identity = struct {
    bytes: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    pub fn bind(self: *Identity, value: []const u8) bool {
        if (value.len == 0 or value.len >= self.bytes.len) return false;
        if (self.len != 0) return self.matches(value);
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
        return true;
    }
    pub fn matches(self: Identity, value: []const u8) bool {
        return self.len != 0 and std.mem.eql(u8, self.bytes[0..self.len], value);
    }
};

/// Charge only time at/after this request began, including a delayed first
/// loop iteration. A previous tick may precede blocked pre-roll/AEC work.
pub fn drainElapsedMs(last_sample_us: i64, request_started_us: i64, now_us: i64) u32 {
    const from_us = @max(last_sample_us, request_started_us);
    return @intCast(@min(@as(i64, 60_000), @divTrunc(@max(@as(i64, 0), now_us - from_us), 1000)));
}

pub const Drain = struct {
    pub const MIN_MS: u32 = 250; // measured synthetic RTP tails reached 126ms
    pub const QUIET_MS: u32 = 150;
    pub const TIMEOUT_MS: u32 = 5000;
    pending: bool = false,
    elapsed_ms: u32 = 0,
    quiet_ms: u32 = 0,
    result: enum { waiting, accepted, rejected } = .waiting,
    pub fn start(self: *Drain) void {
        self.* = .{ .pending = true };
    }
    pub fn acknowledge(self: *Drain, accepted: bool) void {
        if (!self.pending or self.result != .waiting) return;
        self.result = if (accepted) .accepted else .rejected;
        // The ACK does not establish an RTP barrier. Start another quiet window.
        self.quiet_ms = 0;
    }
    pub const Action = enum { none, reopen, close };
    pub fn tick(self: *Drain, received_audio: bool) Action {
        return self.advance(10, received_audio);
    }
    pub fn advance(self: *Drain, elapsed_ms: u32, received_audio: bool) Action {
        if (!self.pending) return .none;
        self.elapsed_ms += elapsed_ms;
        self.quiet_ms = if (received_audio) 0 else self.quiet_ms + elapsed_ms;
        if (self.elapsed_ms >= TIMEOUT_MS) return .close;
        if (self.elapsed_ms >= MIN_MS and
            (self.result == .rejected or
                (self.result == .accepted and self.quiet_ms >= QUIET_MS)))
        {
            self.pending = false;
            return .reopen;
        }
        return .none;
    }
};

/// Authoritative bounded callback mailbox. The RTOS queue only wakes the loop;
/// dropped wake hints cannot lose readiness, latest state, wake, close or ACK.
/// Reset only after the previous room and its callback tasks are destroyed.
pub const Mailbox = struct {
    const reducer = @import("session_reducer.zig");
    const unset: u8 = 255;
    agent_ready: std.atomic.Value(bool) = .init(false),
    mic_ready: std.atomic.Value(bool) = .init(false),
    latest_state: std.atomic.Value(u8) = .init(unset),
    local_wake: std.atomic.Value(bool) = .init(false),
    close: std.atomic.Value(bool) = .init(false),
    accepted_sequence: std.atomic.Value(u32) = .init(0),
    failed_sequence: std.atomic.Value(u32) = .init(0),
    rejected_sequence: std.atomic.Value(u32) = .init(0),

    pub fn publish(self: *Mailbox, event: reducer.Event) void {
        switch (event) {
            .agent_active => |ready| self.agent_ready.store(ready, .release),
            // Publishing the SID bytes happens before this release. Main must
            // acquire mic_ready before reading those immutable session bytes.
            .mic_published => |ready| self.mic_ready.store(ready, .release),
            .agent_state => |state| {
                if (state == .close) self.close.store(true, .release) else self.latest_state.store(@intFromEnum(state), .release);
            },
            .local_wake => self.local_wake.store(true, .release),
            .wake_result => |result| {
                switch (result.outcome) {
                    .accepted => self.accepted_sequence.store(result.sequence, .release),
                    .policy => self.rejected_sequence.store(result.sequence, .release),
                    .failed => self.failed_sequence.store(result.sequence, .release),
                }
            },
            else => {},
        }
    }
    pub const Snapshot = struct {
        agent_ready: bool,
        mic_ready: bool,
        state: ?reducer.AgentState,
        local_wake: bool,
        close: bool,
        accepted_sequence: u32,
        rejected_sequence: u32,
        failed_sequence: u32,
    };
    pub fn take(self: *Mailbox) Snapshot {
        const state = self.latest_state.swap(unset, .acq_rel);
        return .{
            .agent_ready = self.agent_ready.load(.acquire),
            .mic_ready = self.mic_ready.load(.acquire),
            .state = if (state == unset) null else @enumFromInt(state),
            .local_wake = self.local_wake.swap(false, .acq_rel),
            .close = self.close.load(.acquire),
            .accepted_sequence = self.accepted_sequence.swap(0, .acq_rel),
            .failed_sequence = self.failed_sequence.swap(0, .acq_rel),
            .rejected_sequence = self.rejected_sequence.swap(0, .acq_rel),
        };
    }
};
